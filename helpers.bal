import ballerina/http;
import ballerina/io;
import ballerina/persist;
import ballerina/regex;
import ballerina/sql;
import ballerina/uuid;

boolean unschedule_flag = false;

type customerInsert_copy record {|
    string customer_key;
    string environment;
    string product_name;
    string product_base_version;
    string u2_level;
|};

type ci_build_copy record {|
    string uuid;
    string ci_build_id;
    string ci_status;
    string product;
    string version;

    // many-to-one relationship with cicd_build
    cicd_build cicd_build;
|};

type product_regular_update record {|
    string product_name;
    string product_base_version;
|};

type product_hotfix_update record {|
    string product_name;
    string product_base_version;
    string u2_level;
|};

isolated function get_run_result(string run_id) returns json {
    do {
        http:Client pipelineEndpoint = check pipeline_endpoint(ci_pipeline_id);
        json response = check pipelineEndpoint->/runs/[run_id].get(api\-version = "7.1-preview.1");
        return response;
    } on fail var e {
        io:println("Error in function get_run_result");
        io:println(e);
    }
}

isolated function get_map_ci_id_state(map<string> map_product_ci_id) returns map<string> {
    map<string> map_ci_id_state = {};
    foreach string product in map_product_ci_id.keys() {
        string ci_id = <string>map_product_ci_id[product];
        json run = get_run_result(ci_id);
        string run_state = check run.state;
        sql:ParameterizedQuery where_clause = `ci_build_id = ${ci_id}`;
        stream<ci_build, persist:Error?> response = sClient->/ci_builds.get(ci_build, where_clause);
        var ci_build_response = check response.next();
        if ci_build_response !is error? {
            json ci_build_response_json = check ci_build_response.value.fromJsonWithType();
            string ci_build_response_json_id = check ci_build_response_json.id;
            if run_state.equalsIgnoreCaseAscii("completed") {
                string run_result = check run.result;
                ci_build _ = check sClient->/ci_builds/[ci_id].put({
                    ci_status: run_result
                });
                map_ci_id_state[ci_id] = run_result;
            } else {
                map_ci_id_state[ci_id] = run_state;
            }
        }
    } on fail var e {
    	io:println("Error in function get_map_ci_id_state");
    	io:println(e);
    }
    return map_ci_id_state;
}

isolated function initializeClient() returns Client|persist:Error {
    return new Client();
}

isolated function get_customers_to_insert(customerInsert_copy[] list) returns customerInsert[] {
    customerInsert[] cst_info_list = [];

    foreach customerInsert_copy item in list {

        customerInsert tmp = {
            id: uuid:createType4AsString(),
            customer_key: item.customer_key,
            environment: item.environment,
            product_name: item.product_name,
            product_base_version: item.product_base_version,
            u2_level: item.u2_level
        };

        cst_info_list.push(tmp);
    }

    return cst_info_list;
}

isolated function create_product_where_clause(product_regular_update[] product_list) returns sql:ParameterizedQuery {
    sql:ParameterizedQuery where_clause = ``;
    int i = 0;
    while i < product_list.length() {
        if (i == product_list.length() - 1) {
            where_clause = sql:queryConcat(where_clause, `(product_name = ${product_list[i].product_name} AND product_base_version = ${product_list[i].product_base_version})`);
        } else {
            where_clause = sql:queryConcat(where_clause, `(product_name = ${product_list[i].product_name} AND product_base_version = ${product_list[i].product_base_version}) OR `);
        }
        i += 1;
    }
    return where_clause;
}

isolated function getPipelineURL(string organization, string project, string pipeline_id) returns string {
    return "https://dev.azure.com/" + organization + "/" + project + "/_apis/pipelines/" + pipeline_id;
}

isolated function pipeline_endpoint(string pipeline_id) returns http:Client|error {
    http:Client clientEndpoint = check new (getPipelineURL(organization, project, pipeline_id), {
        auth: {
            username: "PAT_AZURE_DEVOPS",
            password: PAT_AZURE_DEVOPS
        }
    }
    );
    return clientEndpoint;
}

isolated function insert_cicd_build(string UUID) returns cicd_buildInsert|error {
    cicd_buildInsert[] cicd_buildInsert_list = [];

    cicd_buildInsert tmp = {
        id: uuid:createType4AsString(),
        uuid: UUID,
        ci_result: "pending",
        cd_result: "pending"
    };

    cicd_buildInsert_list.push(tmp);

    string[] _ = check sClient->/cicd_builds.post(cicd_buildInsert_list);

    return tmp;
}

isolated function create_map_customer_ci_list(string[] product_list, map<string> map_product_ci_id) returns map<string[]> {
    map<string[]> map_customer_product = {};
    // If the product list is type product_regular_update
    foreach string product in product_list {
        // selecting the customers whose deployment has the specific update products
        string product_name = regex:split(product, "-")[0];
        string version = regex:split(product, "-")[1];
        sql:ParameterizedQuery where_clause_product = `(product_name = ${product_name} AND product_base_version = ${version})`;
        stream<customer, persist:Error?> response = sClient->/customers.get(customer, where_clause_product);
        var customer_stream_item = response.next();
        string customer_product_ci_id = <string>map_product_ci_id[product];
        // Iterate on the customer list and maintaining a map to record which builds should be completed for a spcific customer to start tests
        while customer_stream_item !is error? {
            json customer = check customer_stream_item.value.fromJsonWithType();
            string customer_name = check customer.customer_key;
            string[] tmp;
            if map_customer_product.hasKey(customer_name) {
                tmp = <string[]>map_customer_product[customer_name];
                tmp.push(customer_product_ci_id);
            } else {
                tmp = [];
                tmp.push(customer_product_ci_id);
            }
            map_customer_product[customer_name] = tmp;
            customer_stream_item = response.next();
        } on fail var e {
            io:println("Error in function create_customer_product_map");
            io:println(e);
        }
    }
    io:println(map_customer_product);
    return map_customer_product;
}

isolated function get_pending_ci_uuid_list() returns string[] {
    sql:ParameterizedQuery where_clause = `ci_result = "pending"`;
    string[] uuid_list = [];
    stream<customer, persist:Error?> response = sClient->/customers.get(customer, where_clause);
    var uuid_response = response.next();
    while uuid_response !is error? {
        json uuid_record = check uuid_response.value.fromJsonWithType();
        string uuid = check uuid_record.uuid;
        uuid_list.push(uuid);
        uuid_response = response.next();
    } on fail var e {
        io:println("Error in function get_uuid_list ");
        io:println(e);
    }
    return uuid_list;
}

isolated function update_ci_status(string[] uuid_list) {
    do {
        http:Client pipelineEndpoint = check pipeline_endpoint(ci_pipeline_id);
        sql:ParameterizedQuery where_clause = ``;
        int i = 0;
        foreach string uuid in uuid_list {
            if (i == uuid_list.length() - 1) {
                where_clause = sql:queryConcat(where_clause, `uuid = ${uuid}`);
            } else {
                where_clause = sql:queryConcat(where_clause, `uuid = ${uuid} OR `);
            }
            i += 1;
        }
        stream<ci_build, persist:Error?> response = sClient->/ci_builds.get(ci_build, where_clause);
        var ci_build_response = response.next();
        while ci_build_response !is error? {
            json ci_build_response_json = check ci_build_response.value.fromJsonWithType();
            string ci_build_id = check ci_build_response_json.ci_build_id;
            string ci_id = check ci_build_response_json.id;
            json run_response = check pipelineEndpoint->/runs/[ci_build_id].get(api\-version = "7.1-preview.1");
            string run_state = check run_response.state;
            string run_result;
            if ("completed".equalsIgnoreCaseAscii(run_state)) {
                run_result = check run_response.result;
            } else {
                run_result = check run_response.state;
            }
            ci_build _ = check sClient->/ci_builds/[ci_id].put({
                ci_status: run_result
            });
            ci_build_response = response.next();
        } on fail var e {
            io:println("Error in function get_uuid_list ");
            io:println(e);
        }
    } on fail var e {
        io:println("Error in function update_ci_status");
        io:println(e);
    }
}

isolated function update_parent_ci_status(string[] uuid_list) {
    do {
        foreach string uuid in uuid_list {
            sql:ParameterizedQuery where_clause = `uuid = ${uuid}`;
            stream<ci_build, persist:Error?> response = sClient->/ci_builds.get(ci_build, where_clause);
            var ci_build_response = response.next();
            boolean flag = true;
            while ci_build_response !is error? {
                json ci_build_response_json = check ci_build_response.value.fromJsonWithType();
                string ci_build_status = check ci_build_response_json.ci_status;
                if (!ci_build_status.equalsIgnoreCaseAscii("succeeded")) {
                    flag = false;
                }
                ci_build_response = response.next();
            }
            if flag {
                stream<cicd_build, persist:Error?> cicd_response = sClient->/cicd_builds.get(cicd_build, `uuid = ${uuid}`);
                var cicd_build_response = check cicd_response.next();
                if cicd_build_response !is error? {
                    json cicd_build_response_json = check cicd_build_response.value.fromJsonWithType();
                    string cicd_id = check cicd_build_response_json.id;
                    cicd_build _ = check sClient->/cicd_builds/[cicd_id].put({
                        ci_result: "succeeded"
                    });
                }

            }
        }
    } on fail var e {
        io:println("Error in function update_parent_ci_status");
        io:println(e);
    }
}

isolated function get_map_product_ci_id(string uuid) returns map<string> {
    sql:ParameterizedQuery where_clause = `uuid = ${uuid}`;
    stream<ci_build, persist:Error?> response = sClient->/ci_builds.get(ci_build, where_clause);
    map<string> map_product_ci_id = {};
    var ci_build_repsonse = response.next();
    while ci_build_repsonse !is error? {
        json ci_build_repsonse_json = check ci_build_repsonse.value.fromJsonWithType();
        string product_name = check ci_build_repsonse_json.product;
        string version = check ci_build_repsonse_json.version;
        string ci_build_id = check ci_build_repsonse_json.ci_build_id;
        map_product_ci_id[string:'join("-", product_name, version)] = ci_build_id;
        ci_build_repsonse = response.next();
    } on fail var e {
        io:println("Error in function get_map_product_ci_id");
        io:println(e);
    }
    return map_product_ci_id;
}

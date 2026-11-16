// Synthetic JSON-RPC peer for testing host config policy, not the Codex runtime.
using System;
using System.Collections.Generic;
using System.IO;
using System.Web.Script.Serialization;

class CodexConfigServer {
    public static int Main(string[] args) {
        string path = Environment.GetEnvironmentVariable("WORKSTATION_CODEX_TEST_CASE");
        if (args.Length != 1 || args[0] != "app-server" || String.IsNullOrEmpty(path)) return 64;
        var json = new JavaScriptSerializer();
        var fixture = json.Deserialize<Dictionary<string, object>>(File.ReadAllText(path));
        try {
            string line;
            while ((line = Console.ReadLine()) != null) {
                var request = json.Deserialize<Dictionary<string, object>>(line);
                if (!request.ContainsKey("id")) continue;
                string method = (string)request["method"];
                if (method == "initialize" && fixture.ContainsKey("serverRequest")) {
                    Console.WriteLine(json.Serialize(new { id = 900, method = "account/login/start", @params = new { } }));
                    continue;
                }
                var reply = new Dictionary<string, object>();
                reply["id"] = request["id"];
                if (method == "initialize") reply["result"] = new Dictionary<string, object>();
                else if (method == "config/read") reply["result"] = fixture["read"];
                else if (method == "config/batchWrite") {
                    File.AppendAllText((string)fixture["capture"], line + "\n");
                    if (fixture.ContainsKey("rejectWrite")) {
                        reply["error"] = new { code = 409, message = "synthetic-private-marker-must-not-be-printed" };
                    } else reply["result"] = new Dictionary<string, object>();
                } else return 65;
                Console.WriteLine(json.Serialize(reply));
                Console.Out.Flush();
            }
            return 0;
        } finally { File.WriteAllText((string)fixture["exited"], "EOF"); }
    }
}

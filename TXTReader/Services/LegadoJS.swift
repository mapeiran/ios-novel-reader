import Foundation
import JavaScriptCore
import CryptoKit

/// 为 Legado 的 @js: 规则提供 JavaScriptCore 运行环境与最小 java.* 兼容层
enum LegadoJS {

    static func install(context: JSContext,
                        source: [String: Any],
                        baseURL: String,
                        fetchSync: @escaping (String, String?) -> String?,
                        log: @escaping (String) -> Void) {

        let logFn: @convention(block) (String) -> Void = { message in log(message) }
        context.setObject(logFn, forKeyedSubscript: "__log" as NSString)

        let ajaxFn: @convention(block) (String) -> String = { url in
            let body = fetchSync(url, nil) ?? ""
            let dict: [String: Any] = ["body": body, "code": body.isEmpty ? 0 : 200, "header": [String: String]()]
            if let data = try? JSONSerialization.data(withJSONObject: dict),
               let string = String(data: data, encoding: .utf8) { return string }
            return "{\"body\":\"\",\"code\":0,\"header\":{}}"
        }
        context.setObject(ajaxFn, forKeyedSubscript: "__ajax" as NSString)

        let b64e: @convention(block) (String) -> String = { Data($0.utf8).base64EncodedString() }
        context.setObject(b64e, forKeyedSubscript: "__b64e" as NSString)
        let b64d: @convention(block) (String) -> String = {
            String(data: Data(base64Encoded: $0) ?? Data(), encoding: .utf8) ?? ""
        }
        context.setObject(b64d, forKeyedSubscript: "__b64d" as NSString)
        let md5: @convention(block) (String) -> String = { text in
            Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        context.setObject(md5, forKeyedSubscript: "__md5" as NSString)

        let sourceJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: source),
           let string = String(data: data, encoding: .utf8) {
            sourceJSON = string
        } else {
            sourceJSON = "{}"
        }
        context.setObject(sourceJSON, forKeyedSubscript: "__sourceJSON" as NSString)
        context.setObject(baseURL, forKeyedSubscript: "__baseURL" as NSString)

        context.evaluateScript(prelude)
    }

    private static let prelude = #"""
    function __mkResp(json){
      var o;
      try { o = JSON.parse(json); } catch(e){ o = { body: String(json||''), code: 200, header: {} }; }
      return {
        body: function(){ return o.body || ''; },
        header: function(k){ return (o.header && o.header[k]) || ''; },
        code: function(){ return o.code || 200; },
        raw: function(){ return o.body || ''; }
      };
    }
    var java = {
      ajax: function(u){ return __mkResp(__ajax(String(u))); },
      get: function(u){ return __mkResp(__ajax(String(u))); },
      post: function(u){ return __mkResp(__ajax(String(u))); },
      connect: function(u){ return __mkResp(__ajax(String(u))); },
      log: function(){ var a=[]; for (var i=0;i<arguments.length;i++){ a.push(String(arguments[i])); } __log(a.join(' ')); },
      base64Encode: function(s){ return __b64e(String(s)); },
      base64Decode: function(s){ return __b64d(String(s)); },
      md5Encode: function(s){ return __md5(String(s)); },
      timeFormat: function(){ var d=new Date(); function p(n){return (n<10?'0':'')+n;} return d.getFullYear()+'-'+p(d.getMonth()+1)+'-'+p(d.getDate())+' '+p(d.getHours())+':'+p(d.getMinutes())+':'+p(d.getSeconds()); },
      toast: function(){},
      setCookie: function(){},
      getCookie: function(){ return ''; },
      hexDecodeToString: function(s){ return String(s); },
      logType: {}
    };
    var cookie = { getCookie: function(){ return ''; }, setCookie: function(){}, removeCookie: function(){} };
    var source = JSON.parse(__sourceJSON);
    var baseUrl = __baseURL;
    """#
}

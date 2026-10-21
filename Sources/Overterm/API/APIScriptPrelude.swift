/// The JavaScript every script runs after: Bruno's `bru`, `req`, `res`,
/// `test` and a Chai-style `expect`, over `__input` (JSON the runtime
/// hands in) and into `__output` (JSON it reads back). Kept to what
/// scripts in Bruno collections actually call; `require` says plainly that
/// npm packages need `bru`.
enum APIScriptPrelude {
    static let source = #"""
        "use strict";
        var __in = JSON.parse(__input);
        var __out = { runtime: {}, deleted: [], env: {}, logs: [], tests: [], next: undefined, skip: false, stop: false,
                      req: null, resBody: undefined };
        var __vars = __in.vars || {};
        var __runtime = __in.runtimeTyped || __in.runtime || {};
        var __env = __in.env || {};

        function __str(v) {
          if (v === undefined) return "undefined";
          if (typeof v === "string") return v;
          try { return JSON.stringify(v); } catch (e) { return String(v); }
        }

        var console = {};
        ["log", "info", "warn", "error", "debug"].forEach(function (level) {
          console[level] = function () {
            var parts = Array.prototype.slice.call(arguments).map(__str);
            __out.logs.push({ level: level === "debug" || level === "info" ? "log" : level, text: parts.join(" ") });
          };
        });

        function require(name) {
          throw new Error("require('" + name + "') isn't available in Overterm's script runtime — run this collection with bru for npm packages.");
        }

        function __interpolate(text) {
          if (typeof text !== "string") return text;
          return text.replace(/\{\{\s*([^{}]+?)\s*\}\}/g, function (all, name) {
            if (Object.prototype.hasOwnProperty.call(__runtime, name)) return __str(__runtime[name]);
            if (Object.prototype.hasOwnProperty.call(__vars, name)) return __vars[name];
            if (name.indexOf("process.env.") === 0) {
              var v = (__in.processEnv || {})[name.slice(12)];
              return v === undefined ? all : v;
            }
            return all;
          });
        }

        var bru = {
          setVar: function (name, value) {
            __runtime[name] = value; __out.runtime[name] = value;
            // Set after a deleteVar: the setting wins, as it came last.
            __out.deleted = __out.deleted.filter(function (n) { return n !== name; });
          },
          getVar: function (name) {
            if (Object.prototype.hasOwnProperty.call(__runtime, name)) return __runtime[name];
            return __vars[name];
          },
          hasVar: function (name) { return Object.prototype.hasOwnProperty.call(__runtime, name) || Object.prototype.hasOwnProperty.call(__vars, name); },
          deleteVar: function (name) { delete __runtime[name]; delete __out.runtime[name]; __out.deleted.push(name); },
          getEnvVar: function (name) { return __env[name]; },
          setEnvVar: function (name, value) { __env[name] = value; __out.env[name] = value; },
          getEnvName: function () { return __in.envName; },
          getProcessEnv: function (name) { return (__in.processEnv || {})[name]; },
          getCollectionName: function () { return __in.collectionName; },
          getRequestVar: function (name) { return (__in.requestVars || {})[name]; },
          getFolderVar: function (name) { return (__in.folderVars || {})[name]; },
          getCollectionVar: function (name) { return (__in.collectionVars || {})[name]; },
          interpolate: function (text) { return __interpolate(text); },
          setNextRequest: function (name) { if (name === null) __out.stop = true; else __out.next = String(name); },
          sleep: function (ms) { return Promise.resolve(); },
          runner: {
            setNextRequest: function (name) { if (name === null) __out.stop = true; else __out.next = String(name); },
            skipRequest: function () { __out.skip = true; },
            stopExecution: function () { __out.stop = true; }
          }
        };

        function __headerName(headers, name) {
          var lower = String(name).toLowerCase();
          for (var key in headers) if (key.toLowerCase() === lower) return key;
          return undefined;
        }

        var __req = __in.req || { url: "", method: "GET", headers: {}, body: undefined };
        var req = {
          get url() { return __req.url; }, set url(v) { __req.url = v; __out.req = __req; },
          get method() { return __req.method; }, set method(v) { __req.method = v; __out.req = __req; },
          get headers() { return __req.headers; },
          get body() { return __req.body; }, set body(v) { __req.body = v; __out.req = __req; __out.bodyCleared = (v === null || v === undefined); },
          getUrl: function () { return __req.url; },
          setUrl: function (url) { __req.url = url; __out.req = __req; },
          getMethod: function () { return __req.method; },
          setMethod: function (method) { __req.method = String(method).toUpperCase(); __out.req = __req; },
          getName: function () { return __in.requestName; },
          getHeader: function (name) { var key = __headerName(__req.headers, name); return key === undefined ? undefined : __req.headers[key]; },
          getHeaders: function () { return __req.headers; },
          setHeader: function (name, value) {
            var key = __headerName(__req.headers, name);
            if (key !== undefined) delete __req.headers[key];
            __req.headers[name] = String(value); __out.req = __req;
          },
          setHeaders: function (headers) { __req.headers = Object.assign({}, headers); __out.req = __req; },
          deleteHeader: function (name) { var key = __headerName(__req.headers, name); if (key !== undefined) delete __req.headers[key]; __out.req = __req; },
          getBody: function () { return __req.body; },
          setBody: function (body) { __req.body = body; __out.req = __req; __out.bodyCleared = (body === null || body === undefined); },
          setTimeout: function (ms) { __req.timeout = ms; __out.req = __req; },
          getTimeout: function () { return __req.timeout; }
        };

        function __path(value, path) {
          var parts = String(path).replace(/\[(\w+)\]/g, ".$1").split(".").filter(function (p) { return p.length; });
          for (var i = 0; i < parts.length; i++) {
            if (value === null || value === undefined) return undefined;
            value = value[parts[i]];
          }
          return value;
        }

        var res = null;
        if (__in.res) {
          var __res = __in.res;
          res = function (path) { return __path(__res.body, path); };
          Object.defineProperty(res, "status", { get: function () { return __res.status; } });
          Object.defineProperty(res, "statusText", { get: function () { return __res.statusText; } });
          Object.defineProperty(res, "headers", { get: function () { return __res.headers; } });
          Object.defineProperty(res, "body", { get: function () { return __res.body; } });
          Object.defineProperty(res, "responseTime", { get: function () { return __res.responseTime; } });
          res.getStatus = function () { return __res.status; };
          res.getStatusText = function () { return __res.statusText; };
          res.getHeader = function (name) { var key = __headerName(__res.headers, name); return key === undefined ? undefined : __res.headers[key]; };
          res.getHeaders = function () { return __res.headers; };
          res.getBody = function () { return __res.body; };
          res.setBody = function (body) { __res.body = body; __out.resBody = body; };
          res.getResponseTime = function () { return __res.responseTime; };
          res.getUrl = function () { return __res.url; };
        }

        // ── expect ────────────────────────────────────────────────────────
        function __AssertionError(message) { var e = new Error(message); e.name = "AssertionError"; return e; }

        function __type(v) {
          if (v === null) return "null";
          if (Array.isArray(v)) return "array";
          if (v instanceof RegExp) return "regexp";
          if (v instanceof Date) return "date";
          return typeof v;
        }

        function __deepEqual(a, b) {
          if (a === b) return true;
          if (typeof a === "number" && typeof b === "number" && isNaN(a) && isNaN(b)) return true;
          if (__type(a) !== __type(b)) return false;
          if (Array.isArray(a)) {
            if (a.length !== b.length) return false;
            for (var i = 0; i < a.length; i++) if (!__deepEqual(a[i], b[i])) return false;
            return true;
          }
          if (a instanceof Date) return a.getTime() === b.getTime();
          if (a && typeof a === "object") {
            var ka = Object.keys(a).sort(), kb = Object.keys(b).sort();
            if (!__deepEqual(ka, kb)) return false;
            for (var j = 0; j < ka.length; j++) if (!__deepEqual(a[ka[j]], b[ka[j]])) return false;
            return true;
          }
          return false;
        }

        function __show(v) {
          if (typeof v === "string") return JSON.stringify(v);
          if (v === undefined) return "undefined";
          if (typeof v === "function") return "[Function]";
          try { return JSON.stringify(v); } catch (e) { return String(v); }
        }

        function Assertion(value, message) {
          this._value = value; this._negate = false; this._deep = false; this._message = message;
        }
        Assertion.prototype._assert = function (ok, positive, negative) {
          if (this._negate) ok = !ok;
          if (!ok) throw __AssertionError((this._message ? this._message + ": " : "") + (this._negate ? negative : positive));
          return this;
        };
        ["to", "be", "been", "is", "that", "which", "and", "has", "have", "with", "at", "of", "same", "but", "does", "still", "also"].forEach(function (word) {
          Object.defineProperty(Assertion.prototype, word, { get: function () { return this; } });
        });
        Object.defineProperty(Assertion.prototype, "not", { get: function () { this._negate = !this._negate; return this; } });
        Object.defineProperty(Assertion.prototype, "deep", { get: function () { this._deep = true; return this; } });
        var __flags = {
          ok: function (v) { return [!!v, "expected " + __show(v) + " to be truthy", "expected " + __show(v) + " to be falsy"]; },
          true: function (v) { return [v === true, "expected " + __show(v) + " to be true", "expected " + __show(v) + " not to be true"]; },
          false: function (v) { return [v === false, "expected " + __show(v) + " to be false", "expected " + __show(v) + " not to be false"]; },
          null: function (v) { return [v === null, "expected " + __show(v) + " to be null", "expected " + __show(v) + " not to be null"]; },
          undefined: function (v) { return [v === undefined, "expected " + __show(v) + " to be undefined", "expected " + __show(v) + " not to be undefined"]; },
          NaN: function (v) { return [typeof v === "number" && isNaN(v), "expected " + __show(v) + " to be NaN", "expected " + __show(v) + " not to be NaN"]; },
          exist: function (v) { return [v !== null && v !== undefined, "expected " + __show(v) + " to exist", "expected " + __show(v) + " not to exist"]; },
          empty: function (v) {
            var empty = typeof v === "string" || Array.isArray(v) ? v.length === 0 : (v && typeof v === "object" ? Object.keys(v).length === 0 : false);
            return [empty, "expected " + __show(v) + " to be empty", "expected " + __show(v) + " not to be empty"];
          }
        };
        Object.keys(__flags).forEach(function (flag) {
          Object.defineProperty(Assertion.prototype, flag, { get: function () { var r = __flags[flag](this._value); return this._assert(r[0], r[1], r[2]); } });
        });
        Assertion.prototype.equal = Assertion.prototype.equals = Assertion.prototype.eq = function (expected) {
          var ok = this._deep ? __deepEqual(this._value, expected) : this._value === expected;
          return this._assert(ok, "expected " + __show(this._value) + " to " + (this._deep ? "deeply " : "") + "equal " + __show(expected),
            "expected " + __show(this._value) + " not to " + (this._deep ? "deeply " : "") + "equal " + __show(expected));
        };
        Assertion.prototype.eql = function (expected) { this._deep = true; return this.equal(expected); };
        Assertion.prototype.a = Assertion.prototype.an = function (type) {
          var t = __type(this._value);
          return this._assert(t === String(type).toLowerCase(), "expected " + __show(this._value) + " to be a " + type + " (it is " + t + ")",
            "expected " + __show(this._value) + " not to be a " + type);
        };
        Assertion.prototype.include = Assertion.prototype.includes = Assertion.prototype.contain = Assertion.prototype.contains = function (item) {
          var v = this._value, ok;
          if (typeof v === "string") ok = v.indexOf(item) !== -1;
          else if (Array.isArray(v)) ok = v.some(function (x) { return __deepEqual(x, item); });
          else if (v && typeof v === "object" && item && typeof item === "object") ok = Object.keys(item).every(function (k) { return __deepEqual(v[k], item[k]); });
          else ok = false;
          return this._assert(ok, "expected " + __show(v) + " to include " + __show(item), "expected " + __show(v) + " not to include " + __show(item));
        };
        Assertion.prototype.property = function (name, value) {
          var v = this._value;
          var has = v !== null && v !== undefined && (this._deep ? __path(v, name) !== undefined : name in Object(v));
          var actual = has ? (this._deep ? __path(v, name) : v[name]) : undefined;
          if (arguments.length > 1) {
            this._assert(has && __deepEqual(actual, value), "expected " + __show(v) + " to have property " + __show(name) + " of " + __show(value) + " (it is " + __show(actual) + ")",
              "expected " + __show(v) + " not to have property " + __show(name) + " of " + __show(value));
          } else {
            this._assert(has, "expected " + __show(v) + " to have property " + __show(name), "expected " + __show(v) + " not to have property " + __show(name));
          }
          if (has && !this._negate) { var next = new Assertion(actual, this._message); return next; }
          return this;
        };
        Assertion.prototype.lengthOf = function (n) {
          var len = this._value == null ? undefined : this._value.length;
          return this._assert(len === n, "expected " + __show(this._value) + " to have length " + n + " (it has " + len + ")",
            "expected " + __show(this._value) + " not to have length " + n);
        };
        Object.defineProperty(Assertion.prototype, "length", { get: function () { var self = this; var f = function (n) { return self.lengthOf(n); }; return f; } });
        function __compare(name, test, word) {
          Assertion.prototype[name] = function (n) {
            return this._assert(test(this._value, n), "expected " + __show(this._value) + " to be " + word + " " + __show(n),
              "expected " + __show(this._value) + " not to be " + word + " " + __show(n));
          };
        }
        __compare("above", function (a, b) { return a > b; }, "above");
        __compare("gt", function (a, b) { return a > b; }, "above");
        __compare("greaterThan", function (a, b) { return a > b; }, "above");
        __compare("least", function (a, b) { return a >= b; }, "at least");
        __compare("gte", function (a, b) { return a >= b; }, "at least");
        __compare("below", function (a, b) { return a < b; }, "below");
        __compare("lt", function (a, b) { return a < b; }, "below");
        __compare("lessThan", function (a, b) { return a < b; }, "below");
        __compare("most", function (a, b) { return a <= b; }, "at most");
        __compare("lte", function (a, b) { return a <= b; }, "at most");
        Assertion.prototype.within = function (low, high) {
          return this._assert(this._value >= low && this._value <= high, "expected " + __show(this._value) + " to be within " + low + ".." + high,
            "expected " + __show(this._value) + " not to be within " + low + ".." + high);
        };
        Assertion.prototype.match = Assertion.prototype.matches = function (re) {
          return this._assert(re.test(String(this._value)), "expected " + __show(this._value) + " to match " + re, "expected " + __show(this._value) + " not to match " + re);
        };
        Assertion.prototype.oneOf = function (list) {
          var v = this._value;
          return this._assert(list.some(function (x) { return __deepEqual(x, v); }), "expected " + __show(v) + " to be one of " + __show(list),
            "expected " + __show(v) + " not to be one of " + __show(list));
        };
        Assertion.prototype.keys = Assertion.prototype.key = function () {
          var wanted = Array.isArray(arguments[0]) ? arguments[0] : Array.prototype.slice.call(arguments);
          var have = this._value && typeof this._value === "object" ? Object.keys(this._value) : [];
          var ok = wanted.every(function (k) { return have.indexOf(k) !== -1; });
          return this._assert(ok, "expected " + __show(this._value) + " to have keys " + __show(wanted), "expected " + __show(this._value) + " not to have keys " + __show(wanted));
        };
        Assertion.prototype.instanceOf = Assertion.prototype.instanceof = function (type) {
          return this._assert(this._value instanceof type, "expected " + __show(this._value) + " to be an instance of " + (type && type.name),
            "expected " + __show(this._value) + " not to be an instance of " + (type && type.name));
        };
        Assertion.prototype.satisfy = function (fn) {
          return this._assert(!!fn(this._value), "expected " + __show(this._value) + " to satisfy the function", "expected " + __show(this._value) + " not to satisfy the function");
        };
        Assertion.prototype.status = function (code) {
          var s = this._value && this._value.status !== undefined ? this._value.status : this._value;
          return this._assert(s === code, "expected status " + s + " to be " + code, "expected status not to be " + code);
        };
        function expect(value, message) { return new Assertion(value, message); }
        expect.fail = function (message) { throw __AssertionError(message || "expect.fail()"); };
        function assert(value, message) { if (!value) throw __AssertionError(message || "assertion failed"); }
        assert.equal = function (a, b, m) { if (a != b) throw __AssertionError(m || ("expected " + __show(a) + " to equal " + __show(b))); };
        assert.strictEqual = function (a, b, m) { if (a !== b) throw __AssertionError(m || ("expected " + __show(a) + " to equal " + __show(b))); };
        assert.deepEqual = function (a, b, m) { if (!__deepEqual(a, b)) throw __AssertionError(m || ("expected " + __show(a) + " to deeply equal " + __show(b))); };
        assert.ok = assert;
        assert.fail = function (m) { throw __AssertionError(m || "assert.fail()"); };

        // ── test ──────────────────────────────────────────────────────────
        var __pending = [];
        function test(name, fn) {
          var started = Date.now();
          function record(error) {
            __out.tests.push({ name: String(name), passed: !error, error: error ? String(error && error.message || error) : null, ms: Date.now() - started });
          }
          try {
            var result = fn();
            if (result && typeof result.then === "function") {
              __pending.push(result.then(function () { record(null); }, function (e) { record(e); }));
            } else {
              record(null);
            }
          } catch (e) {
            record(e);
          }
        }

        // ── assert { } blocks ─────────────────────────────────────────────
        function __literal(text) {
          text = String(text).trim();
          if (text === "") return "";
          if (text === "true") return true;
          if (text === "false") return false;
          if (text === "null") return null;
          if (text === "undefined") return undefined;
          if (/^-?\d+(\.\d+)?$/.test(text)) return Number(text);
          if ((text[0] === '"' && text[text.length - 1] === '"') || (text[0] === "'" && text[text.length - 1] === "'")) return text.slice(1, -1);
          if (text[0] === "[" || text[0] === "{") { try { return JSON.parse(text); } catch (e) {} }
          return __interpolate(text);
        }

        function __lhs(expr) {
          expr = String(expr).trim();
          if (expr === "res.status") return res.status;
          if (expr === "res.statusText") return res.statusText;
          if (expr === "res.responseTime") return res.responseTime;
          if (expr.indexOf("res.headers.") === 0) return res.getHeader(expr.slice(12));
          if (expr === "res.body") return res.body;
          if (expr.indexOf("res.body.") === 0 || expr.indexOf("res.body[") === 0) return __path(res.body, expr.slice(8).replace(/^\./, ""));
          return (new Function("res", "req", "bru", "return (" + expr + ");"))(res, req, bru);
        }

        function __assertion(lhsExpr, rule) {
          var started = Date.now();
          var space = String(rule).trim().indexOf(" ");
          var op = space === -1 ? String(rule).trim() : String(rule).trim().slice(0, space);
          var arg = space === -1 ? "" : String(rule).trim().slice(space + 1);
          var known = ["eq","neq","gt","gte","lt","lte","in","notIn","contains","notContains","length","matches","notMatches","startsWith","endsWith","between",
                       "isEmpty","isNotEmpty","isNull","isUndefined","isDefined","isTruthy","isFalsy","isJson","isNumber","isString","isBoolean","isArray"];
          if (known.indexOf(op) === -1) { op = "eq"; arg = String(rule).trim(); }
          var name = lhsExpr + ": " + rule;
          try {
            var v = __lhs(lhsExpr), a = __literal(arg), ok;
            switch (op) {
              case "eq": ok = __deepEqual(v, a) || String(v) === String(a); break;
              case "neq": ok = !(__deepEqual(v, a) || String(v) === String(a)); break;
              case "gt": ok = v > a; break;
              case "gte": ok = v >= a; break;
              case "lt": ok = v < a; break;
              case "lte": ok = v <= a; break;
              case "in": ok = String(arg).split(",").map(function (x) { return __literal(x); }).some(function (x) { return __deepEqual(x, v); }); break;
              case "notIn": ok = !String(arg).split(",").map(function (x) { return __literal(x); }).some(function (x) { return __deepEqual(x, v); }); break;
              case "contains": ok = Array.isArray(v) ? v.some(function (x) { return __deepEqual(x, a); }) : String(v).indexOf(String(a)) !== -1; break;
              case "notContains": ok = Array.isArray(v) ? !v.some(function (x) { return __deepEqual(x, a); }) : String(v).indexOf(String(a)) === -1; break;
              case "length": ok = v != null && v.length === Number(a); break;
              case "matches": ok = new RegExp(String(a)).test(String(v)); break;
              case "notMatches": ok = !new RegExp(String(a)).test(String(v)); break;
              case "startsWith": ok = String(v).indexOf(String(a)) === 0; break;
              case "endsWith": ok = String(v).slice(-String(a).length) === String(a); break;
              case "between": var r = String(arg).split(",").map(function (x) { return Number(x.trim()); }); ok = v >= r[0] && v <= r[1]; break;
              case "isEmpty": ok = v === "" || (Array.isArray(v) && v.length === 0) || (v && typeof v === "object" && Object.keys(v).length === 0); break;
              case "isNotEmpty": ok = !(v === "" || v == null || (Array.isArray(v) && v.length === 0) || (typeof v === "object" && Object.keys(v).length === 0)); break;
              case "isNull": ok = v === null; break;
              case "isUndefined": ok = v === undefined; break;
              case "isDefined": ok = v !== undefined; break;
              case "isTruthy": ok = !!v; break;
              case "isFalsy": ok = !v; break;
              case "isJson": ok = v !== null && typeof v === "object"; break;
              case "isNumber": ok = typeof v === "number"; break;
              case "isString": ok = typeof v === "string"; break;
              case "isBoolean": ok = typeof v === "boolean"; break;
              case "isArray": ok = Array.isArray(v); break;
            }
            __out.tests.push({ name: name, passed: !!ok, error: ok ? null : "expected " + lhsExpr + " (" + __show(v) + ") to " + op + (arg ? " " + arg : ""), ms: Date.now() - started, assertion: true });
          } catch (e) {
            __out.tests.push({ name: name, passed: false, error: String(e && e.message || e), ms: Date.now() - started, assertion: true });
          }
        }

        function __capture(name, expr) {
          try {
            var value = __lhs(expr);
            __runtime[name] = value;
            __out.runtime[name] = value;
          } catch (e) {
            __out.logs.push({ level: "error", text: "vars:post-response " + name + ": " + (e && e.message || e) });
          }
        }

        function __finish() {
          // The request as the script left it, set through req's setters or
          // changed in place (req.headers["X"] = …, req.body.x = …).
          if (__in.req) __out.req = __req;
          return JSON.stringify(__out, function (key, value) { return value === undefined ? null : value; });
        }
        """#
}

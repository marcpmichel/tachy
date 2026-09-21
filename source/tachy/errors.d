module tachy.errors;

/// User-facing error: bad configuration, unreachable host, failed task, ...
class TachyError : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure {
        super(msg, file, line);
    }
}

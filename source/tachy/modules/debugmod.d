module tachy.modules.debugmod;

/**
 * `debug` module — display a message, nothing more:
 *
 *     debug "a message"
 *     debug "myvar = {{myvar}}"
 *
 * The statement key is the message; it renders like every string in job
 * parameters, so `{{ ... }}` references resolve against the host's
 * scope.  The job never fails and never reports `changed` — it only
 * prints, as `debug <message>`, when the host's job line is produced.
 * Like `ensure` and `http` jobs it runs in check mode too (it is pure
 * display, nothing is applied), and it touches no transport.
 */
import tachy.modules : TaskContext, TaskResult;
import tachy.value : Val;

TaskResult runDebugModule(Val[string] params, TaskContext ctx)
{
    // The message travels as the job's label ("debug <message>"); the
    // result itself carries no extra text, so the rendered line is the
    // message exactly.  Validation happens at load time: no parameters
    // beyond the injected message key.
    TaskResult res;
    res.changed = false;
    res.msg = "";
    return res;
}

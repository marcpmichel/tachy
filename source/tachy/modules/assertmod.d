module tachy.modules.assertmod;

/**
 * `assert` module — test a rendered variable value against ensure's
 * output patterns, without touching the host:
 *
 *     assert "the port" {
 *         value = "{{ http_port }}"
 *         equals = "8080"
 *     }
 *     assert "sane environment" {
 *         value = "{{ deploy_env }}"
 *         contains = "prod",
 *         not = { contains = "test" }
 *     }
 *
 * `value` is the string under test — templated like every job
 * parameter, so `{{ ... }}` references resolve against the host's
 * scope.  The expectation keys are the shapes of `ensure`'s `output`:
 * `equals` (exact match), `contains` (substring), `matches` (regular
 * expression), composed with `not`, `any`, `all` and `none` — several
 * keys in one block all must hold, and at least one key is required.
 * The same parser validates the shapes (and compiles the regexes) at
 * load time, then evaluates them at run time against the rendered
 * value.
 *
 * Variables only: host state is out of reach here (probe it with
 * `ensure`).  A check by nature: assert jobs run in check mode too,
 * never report `changed` and touch no transport.
 */
import tachy.modules : TaskContext, TaskResult, requireStr;
import tachy.modules.ensuremod : excerpt, parseOutput;
import tachy.errors;
import tachy.value : Val, dupTable;

/// The expectation table: every param except the injected assertion
/// name and the value itself.  An empty table asserts nothing — an
/// error naming `context`.  Shared with the load-time validation in
/// tachy.modules, so both spellings of "no expectation" fail with the
/// same message.
package(tachy) Val assertionExpectation(in Val[string] params, string context)
@safe pure {
    auto t = dupTable(params);
    t.remove("name");
    t.remove("value");
    if(!t.length)
        throw new TachyError(
                context ~ ": the assertion needs at least one of"
                ~ " 'equals', 'contains', 'matches', 'not', 'any', 'all' and"
                ~ " 'none'");
    Val r;
    r.kind = Val.Kind.table_;
    r.table_ = t;
    return r;
}

TaskResult runAssertModule(Val[string] params, TaskContext ctx) {
    const string name = requireStr(params, "name", "assert");
    const string value = requireStr(params, "value", "assert");
    // The shapes were validated at load time; this second parse runs
    // against the rendered patterns (they may hold templates too).
    auto exp = parseOutput(
            assertionExpectation(params, "assert '" ~ name ~ "'"),
            "assert '" ~ name ~ "'");
    if(!exp.matches(value))
        throw new TachyError("assert '" ~ name ~ "': value '" ~ excerpt(value)
                ~ "' does not satisfy " ~ exp.describe());

    TaskResult res;
    res.changed = false;
    return res;
}

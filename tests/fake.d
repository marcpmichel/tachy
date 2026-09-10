module tachy.tests.fake;


import tachy.transport : CommandResult, Transport;

/// Scripted transport for module unit tests: records every command and
/// pops queued replies in order.
final class FakeTransport : Transport
{
    string[] commands;
    CommandResult[] replies;
    string lastInput;

    override CommandResult run(string command)
    {
        commands ~= command;
        return next();
    }

    override CommandResult runWithInput(string command, string input)
    {
        commands ~= command;
        lastInput = input;
        return next();
    }

    override string describe() const { return "fake"; }

    private CommandResult next()
    {
        if (replies.length == 0)
            return CommandResult(0, "", "");
        auto r = replies[0];
        replies = replies[1 .. $];
        return r;
    }
}



Tofu defines own error set:
```zig title="Partial tofu error set"
pub const AmpeError = error{
    NotImplementedYet,
    WrongConfiguration,
    NotAllowed,
    NullMessage,
    ............
    PoolEmpty,
    AllocationFailed,
    ............
    ShutdownStarted,
    ProcessingFailed, 
    UnknownError,
};
```
There is also enumerator for statuses:
```zig title="Partial tofu statuses"
pub const AmpeStatus = enum(u8) {
    success = 0,
    not_implemented_yet,
    wrong_configuration,
    not_allowed,
    null_message,
    ............
    pool_empty,
    allocation_failed,
    ............
    shutdown_started,
    ............
    processing_failed,
    unknown_error,
};
```

Every _AmpeError_ has corresponding _AmpeStatus_ enumerator (except 'success').

Errors and Statuses have self-described names which I hope means I don’t have to describe each one separately.

To jump ahead a bit, this system allows errors to be transmitted as part of Message,
using just 1 byte (u8).

You can use helper function `#!zig status.raw_to_error(rs: u8) AmpeError!void` in order
to convert byte to corresponding error.

Not every non-zero status means an error right away. It depends on the situation.  
For example, '_channel_closed_'

- is not an error if you requested to close the channel
- it is an error if it happens in the middle of communication


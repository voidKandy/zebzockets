# ZebZockets
This is a WIP [RFC compliant](https://www.rfc-editor.org/rfc/rfc6455.html) web sockets implementation in `zig`.
Everything in the `src` directory is a library shared by the `server` and `client` binaries.


### Framing api
Creating data frame is fairly simple. This library provides two functions for defining `types` that can be used for both the application and extension datas to be used in a given frame:
```zig
pub fn ApplicationData(
    comptime Data: type,
    comptime Error: type,
    comptime SerializeFn: *const fn (ctx: Data, a: Allocator) Error![]u8,
    comptime DeserializeFn: *const fn (bytes: []u8, a: Allocator) Error!Data,
    comptime CleanupFn: ?*const fn (d: Data, a: Allocator) void,
) type {
...
}
pub fn ExtensionData(
    comptime Data: type,
    comptime Error: type,
    comptime CreateFn: ExtDataCtx(Data).CreateFn(Error),
    comptime ReadFn: ExtDataCtx(Data).ReadFn(Error),
    comptime CleanupFn: ?*const fn (d: Data, a: Allocator) void,
) type {
...
}
```
These are helpful to know if you need to manually implement either of these over some type you've defined. In most cases, your application data is likely being sent in `JSON`, so you can use this function to easily define your type for your JSON schema:
```zig
pub fn JsonAppData(
    Data: type,
    parse_options: std.json.ParseOptions,
    stringify_options: std.json.StringifyOptions,
) type {
...
}
```
Let's say you have a struct called `Message` which corresponds to the messages passed between client/server on your socket. Assuming you aren't using any extensions, you can create a frame for that struct quite easily:
```zig
const MessageData = zz.frame.JsonAppData(Message, .{}, .{});
/// `NullExt` is also provided by the library for when you are not using extensions 
const MyFrame = Frame(MessageData, NullExt);

fn create_frame(message: Message, allocator: std.mem.Allocator) !MyFrame {
  const data  = try std.json.parseFromValue(Messasge, allocator, message, MessageData.parse_options);
  const frame = try MyFrame.init(.{
    .fin = false,
    .opcode = OpCode.text,
    .app_data = MessageData.from(data),
    .ext_data = null,
    .allocator = allocator,
  });
  return frame;
}
```


## How the client *should* work
### Starting up the client
`-- <host>:<port>` if no `host` or `port` are passed there are defaults set in the shared library
The above command will have the client attempt to connect to a server. If it is successful, it sends it's handshake and attempt to parse the server's returned handshake. If everything goes OK, the web socket connection will be established.

### Sending & receiving frames to the server 
Once the connection has been established a loop should be started in the Terminal to handle user input which can be sent to the server.
Stdin can be attempted to sent to the server at the next chance and stdout should output payloads from the server (not raw frames).
> I don't know very much about input piping so this is a good opportunity to learn stuff like this. Maybe create some tests that utilize piping.



> The server should work similarly but I will wait to outline that once i have some basic client logic written out for this.

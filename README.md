# ZebZockets
This is a WIP [RFC compliant](https://www.rfc-editor.org/rfc/rfc6455.html) web sockets implementation in `zig`.
Everything in the `src` directory is a library shared by the `server` and `client` binaries.


## How the client *should* work
### Starting up the client
`-- <host>:<port>` if no `host` or `port` are passed there are defaults set in the shared library
The above command will have the client attempt to connect to a server. If it is successful, it sends it's handshake and attempt to parse the server's returned handshake. If everything goes OK, the web socket connection will be established.

### Sending & receiving frames to the server 
Once the connection has been established a loop should be started in the Terminal to handle user input which can be sent to the server.
Stdin can be attempted to sent to the server at the next chance and stdout should output payloads from the server (not raw frames).
> I don't know very much about input piping so this is a good opportunity to learn stuff like this. Maybe create some tests that utilize piping.



> The server should work similarly but I will wait to outline that once i have some basic client logic written out for this.

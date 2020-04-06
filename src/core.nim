import uri, strutils, strformat, tables, asyncnet, asynchttpserver, asyncdispatch, parseutils, httpcore, httpclient

const
  maxLine = 8*1024

type Request* = object
  client*: AsyncSocket # TODO: Separate this into a Response object?
  reqMethod*: HttpMethod
  headers*: HttpHeaders
  protocol*: tuple[orig: string, major, minor: int]
  url*: Uri
  hostname*: string    ## The hostname of the client that made the request.
  body*: string
  urlParams*: Table[string, string]


template logMsg*(m: string) : untyped =
  if s.options.debug:
    echo m

template request*: Request =
  req.mget()

template res*: Request =
  req.mget()

proc addHeaders(msg: var string, headers: HttpHeaders) =
  for k, v in headers:
    msg.add(k & ": " & v & "\c\L")

proc respond*(req: Request, code: HttpCode, content: string,
  headers: HttpHeaders = nil): Future[void] =
  ## Responds to the request with the specified ``HttpCode``, headers and
  ## content.
  ##
  ## This procedure will **not** close the client socket.
  ##
  ## Example:
  ##
  ## .. code-block::nim
  ##    import json
  ##    proc handler(req: Request) {.async.} =
  ##      if req.url.path == "/hello-world":
  ##        let msg = %* {"message": "Hello World"}
  ##        let headers = newHttpHeaders([("Content-Type","application/json")])
  ##        await req.respond(Http200, $msg, headers)
  ##      else:
  ##        await req.respond(Http404, "Not Found")
  var msg = "HTTP/1.1 " & $code & "\c\L"

  if headers != nil:
    msg.addHeaders(headers)
  msg.add("Content-Length: ")
  # this particular way saves allocations:
  msg.addInt content.len
  msg.add "\c\L\c\L"
  msg.add(content)
  result = req.client.send(msg)

# type Response* = object
#   headers*: HttpHeaders
#   httpver*: HttpVersion
#   resMethod*: HttpCode
#   urlParams*: Table[string, string]
#   content*: string
#
# proc initResponse*(): Response =
#   result.httpver = HttpVer11
#   result.headers = newHttpHeaders()

type Context* = object
    Req* : Request
    res* : Response

type ServerOptions* = object
  debug*: bool

type MiddlewareFunc* = proc(req: FutureVar[Request], s: ServerOptions ): bool {.closure, gcsafe.}
type HandlerFunc* = proc(req: FutureVar[Request], s: ServerOptions): Future[void] {.nimcall ,closure, gcsafe.}

# split up a large module into several files
include router

type MyServer* = ref object
  options: ServerOptions
  socket: AsyncSocket
  reuseAddr: bool
  reusePort: bool
  maxBody: int
  router: Router
  middlewares: seq[MiddlewareFunc]
  staticDir: string

proc sendStatus(client: AsyncSocket, status: string): Future[void] =
  client.send("HTTP/1.1 " & status & "\c\L\c\L")

proc parseProtocol(protocol: string): tuple[orig: string, major, minor: int] =
  var i = protocol.skipIgnoreCase("HTTP/")
  if i != 5:
    raise newException(ValueError, "Invalid request protocol. Got: " &
        protocol)
  result.orig = protocol
  i.inc protocol.parseSaturatedNatural(result.major, i)
  i.inc # Skip .
  i.inc protocol.parseSaturatedNatural(result.minor, i)

proc parseUppercaseMethod(name: string): HttpMethod =
  result =
    case name
    of "GET": HttpGet
    of "POST": HttpPost
    of "HEAD": HttpHead
    of "PUT": HttpPut
    of "DELETE": HttpDelete
    of "PATCH": HttpPatch
    of "OPTIONS": HttpOptions
    of "CONNECT": HttpConnect
    of "TRACE": HttpTrace
    else: raise newException(ValueError, "Invalid HTTP method " & name)


proc respondError(req: Request, code: HttpCode): Future[void] =
  ## Responds to the request with the specified ``HttpCode``.
  let content = $code
  var msg = "HTTP/1.1 " & content & "\c\L"
  msg.add("Content-Length: " & $content.len & "\c\L\c\L")
  msg.add(content)
  result = req.client.send(msg)

proc processRequest(
  server: MyServer,
  req: FutureVar[Request],
  client: AsyncSocket,
  address: string,
  lineFut: FutureVar[string],
  callback: proc (request: FutureVar[Request] ,s: MyServer, client: AsyncSocket): Future[void] {.closure, gcsafe.},
): Future[bool] {.async.} =

  # Alias `request` to `req.mget()` so we don't have to write `mget` everywhere.
  template request(): Request =
    req.mget()

  # GET /path HTTP/1.1
  # Header: val
  # \n
  request.headers.clear()
  request.body = ""
  request.hostname.shallowCopy(address)
  assert client != nil
  request.client = client

  # We should skip at least one empty line before the request
  # https://tools.ietf.org/html/rfc7230#section-3.5
  for i in 0..1:
    lineFut.mget().setLen(0)
    lineFut.clean()
    await client.recvLineInto(lineFut, maxLength = maxLine) # TODO: Timeouts.

    if lineFut.mget == "":
      client.close()
      return false

    if lineFut.mget.len > maxLine:
      await request.respondError(Http413)
      client.close()
      return false
    if lineFut.mget != "\c\L":
      break

  # First line - GET /path HTTP/1.1
  var i = 0
  for linePart in lineFut.mget.split(' '):
    case i
    of 0:
      try:
        request.reqMethod = parseUppercaseMethod(linePart)
      except ValueError:
        asyncCheck request.respondError(Http400)
        return true # Retry processing of request
    of 1:
      try:
        parseUri(linePart, request.url)
      except ValueError:
        asyncCheck request.respondError(Http400)
        return true
    of 2:
      try:
        request.protocol = parseProtocol(linePart)
      except ValueError:
        asyncCheck request.respondError(Http400)
        return true
    else:
      await request.respondError(Http400)
      return true
    inc i

  # Headers
  while true:
    i = 0
    lineFut.mget.setLen(0)
    lineFut.clean()
    await client.recvLineInto(lineFut, maxLength = maxLine)

    if lineFut.mget == "":
      client.close(); return false
    if lineFut.mget.len > maxLine:
      await request.respondError(Http413)
      client.close(); return false
    if lineFut.mget == "\c\L": break
    let (key, value) = parseHeader(lineFut.mget)
    request.headers[key] = value
    # Ensure the client isn't trying to DoS us.
    if request.headers.len > headerLimit:
      await client.sendStatus("400 Bad Request")
      request.client.close()
      return false

  if request.reqMethod == HttpPost:
    # Check for Expect header
    if request.headers.hasKey("Expect"):
      if "100-continue" in request.headers["Expect"]:
        await client.sendStatus("100 Continue")
      else:
        await client.sendStatus("417 Expectation Failed")

  # Read the body
  # - Check for Content-length header
  if request.headers.hasKey("Content-Length"):
    var contentLength = 0
    if parseSaturatedNatural(request.headers["Content-Length"],
        contentLength) == 0:
      await request.respond(Http400, "Bad Request. Invalid Content-Length.")
      return true
    else:
      if contentLength > server.maxBody:
        await request.respondError(Http413)
        return false
      request.body = await client.recv(contentLength)
      if request.body.len != contentLength:
        await request.respond(Http400, "Bad Request. Content-Length does not match actual.")
        return true
  elif request.reqMethod == HttpPost:
    await request.respond(Http411, "Content-Length required.")
    return true

  # Call the user's callback.
  await callback(req,server,client)

  if "upgrade" in request.headers.getOrDefault("connection"):
    return false

  # The request has been served, from this point on returning `true` means the
  # connection will not be closed and will be kept in the connection pool.

  # Persistent connections
  if (request.protocol == HttpVer11 and
      cmpIgnoreCase(request.headers.getOrDefault("connection"), "close") != 0) or
     (request.protocol == HttpVer10 and
      cmpIgnoreCase(request.headers.getOrDefault("connection"), "keep-alive") == 0):
    # In HTTP 1.1 we assume that connection is persistent. Unless connection
    # header states otherwise.
    # In HTTP 1.0 we assume that the connection should not be persistent.
    # Unless the connection header states otherwise.
    return true
  else:
    request.client.close()
    return false

proc processClient(server: MyServer, client: AsyncSocket, address: string,
                   callback: proc (request: FutureVar[Request] ,s: MyServer, client: AsyncSocket):
                      Future[void] {.closure, gcsafe.}) {.async.} =
  var request = newFutureVar[Request]("MyServer.processClient")
  request.mget().url = initUri()
  request.mget().headers = newHttpHeaders()
  var lineFut = newFutureVar[string]("MyServer.processClient")
  lineFut.mget() = newStringOfCap(80)

  while not client.isClosed:
    let retry = await processRequest(
      server, request, client, address, lineFut, callback
    )
    if not retry: break

proc serve*(server: MyServer, port: Port,
            callback: proc (request: FutureVar[Request] ,s: MyServer, client: AsyncSocket): Future[void] {.closure, gcsafe.},
            address = "") {.async.} =
  ## Starts the process of listening for incoming HTTP connections on the
  ## specified address and port.
  ##
  ## When a request is made by a client the specified callback will be called.
  server.socket = newAsyncSocket()
  if server.reuseAddr:
    server.socket.setSockOpt(OptReuseAddr, true)
  if server.reusePort:
    server.socket.setSockOpt(OptReusePort, true)
  server.socket.bindAddr(port, address)
  server.socket.listen()

  while true:
    var (address, client) = await server.socket.acceptAddr()
    asyncCheck processClient(server, client, address, callback)
    #echo(f.isNil)
    #echo(f.repr)

proc initMyServer*(router: Router, middlewares: seq[MiddlewareFunc], reuseAddr = true, reusePort = false,
maxBody = 8388608, options: ServerOptions): MyServer =
  ## Creates a new ``MyServer`` instance.
  new result
  result.options = options
  result.router = router
  result.middlewares = middlewares
  result.reuseAddr = reuseAddr
  result.reusePort = reusePort
  result.maxBody = maxBody



proc handleClient*(req: FutureVar[Request] ,s: MyServer, client: AsyncSocket) {.async.} =
  # var res = initResponse()
  # res.headers = newHttpHeaders({ "Content-Type": "text/html; charset=UTF-8"})

  for  m in s.middlewares:
    let usenextmiddleware = m(req, s.options)
    if not usenextmiddleware:
      # logMsg "early return from middleware..."
      await request.respond(Http404, "not found") # temprory
      return

  let (routeHandler, params) = s.router.getByPath(request.url.path, request.reqMethod)
  request.urlParams = params
  let handler = routeHandler.handlerFunc
  let middlewares = routeHandler.middlewares

  for  m in middlewares:
    let usenextmiddleware = m(req, s.options)
    if not usenextmiddleware:
    #   logMsg "early return from route middleware..."
      await request.respond(Http404, "not found")
      return

  try :
    yield handler(req=req, s=s.options)
  except:
    raise
    # TODO log Error


proc run*(s: MyServer, port=8080 , address="") =
  asyncCheck s.serve( port = Port(port), handleClient, address = address)
  echo fmt"server started at {address}:{port} {s.options}"
  runForever()

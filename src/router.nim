type RouterValue* = object
  handlerFunc: HandlerFunc
  httpMethod: seq[HttpMethod]
  middlewares:seq[MiddlewareFunc]

type Router* = object
  table: Table[string, RouterValue]
  notFoundHandler: HandlerFunc

proc addRoute*(router: var Router, route: string, handler: HandlerFunc, httpMethod:seq[HttpMethod]= @[HttpGet], middlewares:seq[MiddlewareFunc]= @[]) =
  router.table.add(route, RouterValue(handlerFunc:handler, httpMethod: httpMethod, middlewares:middlewares))

proc handle404*(req: FutureVar[Request],p: pointer) {.async.} =
  await request.respond(Http404 , "Not Found")

proc initRouter*(notFoundHandler:HandlerFunc=handle404): Router =
  result.table =  initTable[string, RouterValue]()
  result.notFoundHandler = notFoundHandler

proc getByPath*(r: Router, path: string, httpMethod=HttpGet) : (RouterValue, Table[string, string]) =
    var found = false
    if path in r.table and httpMethod in r.table[path].httpMethod :
      return (r.table[path],  initTable[string, string]())

    for handlerPath, routerValue in r.table.pairs:
      if httpMethod notin routerValue.httpMethod :
        continue

    #   echo fmt"checking handler: {handlerPath} if it matches {path}"
      let pathParts = path.split({'/'})
      let handlerPathParts = handlerPath.split({'/'})
    #   echo fmt"pathParts {pathParts} and handlerPathParts {handlerPathParts}"

      if len(pathParts) != len(handlerPathParts):
        # echo "length isn't ok"
        continue
      else:
        var idx = 0
        var capturedParams =  initTable[string, string]()

        while idx<len(pathParts):
          let pathPart = pathParts[idx]
          let handlerPathPart = handlerPathParts[idx]
          # echo fmt"current pathPart {pathPart} current handlerPathPart: {handlerPathPart}"

          if handlerPathPart.startsWith(":") or handlerPathPart.startsWith("@"):
            # echo fmt"found var in path {handlerPathPart} matches {pathPart}"
            capturedParams[handlerPathPart[1..^1]] = pathPart
            inc idx
          else:
            if pathPart == handlerPathPart:
              inc idx
            else:
              break

          if idx == len(pathParts):
            found = true
            return (routerValue, capturedParams)

    if not found:

      return (RouterValue(handlerFunc:r.notFoundHandler, middlewares: @[]),  initTable[string, string]())

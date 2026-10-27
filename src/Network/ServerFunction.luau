local gt = require("../../roblox_packages/gt")

local Middleware = require("./Middleware")
local Runtime = require("./Runtime")

export type ServerFunction<A..., R...> = Runtime.InnerNetworkFunction<A..., R...> & {
	_callback: ((A...) -> R...)?,
	On: (self: ServerFunction<A..., R...>, callback: (A...) -> R...) -> () -> (),
	Fire: (self: ServerFunction<A..., R...>, player: Player, A...) -> R...,
	UseRequest: (self: ServerFunction<A..., R...>, middleware: Middleware.Middleware<A...>) -> () -> (),
	UseResponse: (self: ServerFunction<A..., R...>, middleware: Middleware.Middleware<R...>) -> () -> (),
}

export type ServerFunctionBuilder<A...> = <R...>(R...) -> ServerFunction<A..., R...>

local ServerFunction = {}

function ServerFunction.new<A...>(name: string, ...: A...): ServerFunctionBuilder<A...>
	local argsSchema = gt.build(gt.tuple(...))

	return function<R...>(...: R...): ServerFunction<A..., R...>
		local fn = {} :: ServerFunction<A..., R...>

		fn._name = name
		fn._requestMiddleware = {}
		fn._responseMiddleware = {}
		fn._callback = nil
		fn._argsSchema = argsSchema
		fn._returnsSchema = gt.build(gt.tuple(...))

		-- Runs on the client.
		local function respond(...: any): ...any
			return Middleware.run(
				fn._responseMiddleware,
				"ServerFunction", name, "outgoing", "response", nil, nil,
				fn._returnsSchema:assert((fn._callback :: any)(fn._argsSchema:assert(...)))
			)
		end

		function fn:On(callback: (A...) -> R...): () -> ()
			self._callback = callback

			Runtime:registerFunctionCallback(self._name, function(...)
				return respond(Middleware.run(self._requestMiddleware, "ServerFunction", name, "incoming", "request", nil, nil, ...))
			end)

			return function()
				if self._callback == callback then
					self._callback = nil
					Runtime:registerFunctionCallback(self._name, nil)
				end
			end
		end

		-- Runs on the server.
		function fn:Fire(player: Player, ...: A...): R...
			self._argsSchema:assert(...)

			return self._returnsSchema:assert(Middleware.run(
				self._responseMiddleware,
				"ServerFunction", name, "incoming", "response", player, nil,
				Runtime:fireClientFunction(
					self._name,
					player,
					Middleware.run(self._requestMiddleware, "ServerFunction", name, "outgoing", "request", player, nil, ...)
				)
			))
		end

		function fn:UseRequest(middleware: Middleware.Middleware<A...>): () -> ()
			return Middleware.add(self._requestMiddleware, middleware)
		end

		function fn:UseResponse(middleware: Middleware.Middleware<R...>): () -> ()
			return Middleware.add(self._responseMiddleware, middleware)
		end

		Runtime:registerNetworkObject(name)

		return fn
	end
end

return ServerFunction

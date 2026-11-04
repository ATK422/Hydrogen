local gt = require("../../roblox_packages/gt")

local Codec = require("./Codec")
local Middleware = require("./Middleware")
local Runtime = require("./Runtime")

export type ServerFunction<A..., R...> = Runtime.InnerNetworkFunction<A..., R...> & {
	_callback: ((A...) -> R...)?,
	_timeout: number,
	_argsCodec: Codec.Codec?,
	_returnsCodec: Codec.Codec?,
	Encode: (self: ServerFunction<A..., R...>) -> ServerFunction<A..., R...>,
	On: (self: ServerFunction<A..., R...>, callback: (A...) -> R...) -> () -> (),
	Fire: (self: ServerFunction<A..., R...>, player: Player, A...) -> R...,
	UseRequest: (self: ServerFunction<A..., R...>, middleware: Middleware.Middleware<A...>) -> () -> (),
	UseResponse: (self: ServerFunction<A..., R...>, middleware: Middleware.Middleware<R...>) -> () -> (),
	SetTimeout: (self: ServerFunction<A..., R...>, seconds: number) -> ServerFunction<A..., R...>,
}

export type ServerFunctionBuilder<A...> = <R...>(R...) -> ServerFunction<A..., R...>

-- Seconds the server waits for a client to answer before Fire errors.
local DEFAULT_TIMEOUT = 10

local ServerFunction = {}

function ServerFunction.new<A...>(name: string, ...: A...): ServerFunctionBuilder<A...>
	local argsSchema = gt.build(gt.tuple(...))

	return function<R...>(...: R...): ServerFunction<A..., R...>
		local fn = {} :: ServerFunction<A..., R...>

		fn._name = name
		fn._kind = "ServerFunction"
		fn._requestMiddleware = {}
		fn._responseMiddleware = {}
		fn._callback = nil
		fn._timeout = DEFAULT_TIMEOUT
		fn._argsSchema = argsSchema
		fn._returnsSchema = gt.build(gt.tuple(...))
		fn._argsCodec = nil
		fn._returnsCodec = nil

		local function handle(_player: Player?, ...: any): ...any
			return fn._returnsSchema:assert((fn._callback :: any)(...))
		end

		-- Runs on the client.
		local function respond(...: any): ...any
			return Codec.encodeWith(fn._returnsCodec, Middleware.unlessDropped(name, "response", Middleware.run(
				fn._responseMiddleware,
				"ServerFunction", name, "outgoing", "response", nil, nil,
				Runtime:observeCall("ServerFunction", name, Runtime:loopbackClient(), handle, fn._argsSchema:assert(...))
			)))
		end

		function fn:On(callback: (A...) -> R...): () -> ()
			self._callback = callback

			Runtime:registerFunctionCallback(self._name, function(...)
				return respond(Middleware.unlessDropped(name, "request", Middleware.run(
					self._requestMiddleware,
					"ServerFunction", name, "incoming", "request", nil, nil,
					Codec.decodeWith(self._argsCodec, name, "request", ...)
				)))
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

			return self._returnsSchema:assert(Middleware.unlessDropped(name, "response", Middleware.run(
				self._responseMiddleware,
				"ServerFunction", name, "incoming", "response", player, nil,
				Codec.decodeWith(self._returnsCodec, name, "response", Runtime:fireClientFunction(
					self._name,
					player,
					self._timeout,
					Codec.encodeWith(self._argsCodec, Middleware.unlessDropped(name, "request", Middleware.run(self._requestMiddleware, "ServerFunction", name, "outgoing", "request", player, nil, ...)))
				))
			)))
		end

		-- Packs arguments and return values into buffers using the schemas. Both sides must agree,
		-- so call it in the shared definition. Middleware and the handler still see the plain values.
		function fn:Encode(): ServerFunction<A..., R...>
			self._argsCodec = Codec.new(self._argsSchema, name)
			self._returnsCodec = Codec.new(self._returnsSchema, name)
			return self
		end

		-- math.huge waits forever, which lets a client that never answers hang the calling thread.
		function fn:SetTimeout(seconds: number): ServerFunction<A..., R...>
			if type(seconds) ~= "number" or seconds <= 0 then
				error(`[HYDROGEN] {name} timeout must be a positive number of seconds`, 2)
			end
			self._timeout = seconds
			return self
		end

		function fn:UseRequest(middleware: Middleware.Middleware<A...>): () -> ()
			return Middleware.add(self._requestMiddleware, middleware)
		end

		function fn:UseResponse(middleware: Middleware.Middleware<R...>): () -> ()
			return Middleware.add(self._responseMiddleware, middleware)
		end

		Runtime:registerNetworkObject(name, fn)

		return fn
	end
end

return ServerFunction

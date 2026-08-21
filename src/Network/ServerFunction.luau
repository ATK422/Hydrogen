local gt = require("../../roblox_packages/gt")

local Runtime = require("./Runtime")

export type ServerFunction<A..., R...> = Runtime.InnerNetworkFunction<A..., R...> & {
	_callback: ((A...) -> R...)?,
	On: (self: ServerFunction<A..., R...>, callback: (A...) -> R...) -> () -> (),
	Fire: (self: ServerFunction<A..., R...>, player: Player, A...) -> R...,
}

export type ServerFunctionBuilder<A...> = <R...>(R...) -> ServerFunction<A..., R...>

local ServerFunction = {}

function ServerFunction.new<A...>(name: string, ...: A...): ServerFunctionBuilder<A...>
	local argsSchema = gt.build(gt.tuple(...))

	return function<R...>(...: R...): ServerFunction<A..., R...>
		local fn = {} :: ServerFunction<A..., R...>

		fn._name = name
		fn._outgoingMiddleware = {}
		fn._incomingMiddleware = {}
		fn._callback = nil
		fn._argsSchema = argsSchema
		fn._returnsSchema = gt.build(gt.tuple(...))

		function fn:On(callback: (A...) -> R...): () -> ()
			self._callback = callback

			Runtime:registerFunctionCallback(self._name, function(...)
				return self._returnsSchema:assert(callback(self._argsSchema:assert(...)))
			end)

			return function()
				if self._callback == callback then
					self._callback = nil
					Runtime:registerFunctionCallback(self._name, nil)
				end
			end
		end

		function fn:Fire(player: Player, ...: A...): R...
			return self._returnsSchema:assert(
				Runtime:fireClientFunction(self._name, player, self._argsSchema:assert(...))
			)
		end

		Runtime:registerNetworkObject(name)

		return fn
	end
end

return ServerFunction

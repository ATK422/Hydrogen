--!strict

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local Hydrogen = require("../src")

local Messaging = Hydrogen.Messaging
local Scope = Hydrogen.Scope
local gt = Hydrogen.gt

local topics = 0

-- Topic names are VM-wide, so every test gets its own.
local function topicName(): string
	topics += 1
	return `MessagingTest{topics}`
end

local Announcement = gt.table({ text = gt.string(), priority = gt.number({ integer = true }) })
type Announcement = { text: string, priority: number }

local function contains(text: string, part: string): boolean
	return string.find(text, part, 1, true) ~= nil
end

local function errorOf(fn: () -> ()): string
	local ok, err = pcall(fn)
	check.equal(ok, false)
	return tostring(err)
end

return function()
	test.suite("Messaging", function()
		test.case("publishes a typed value and delivers it to subscribers, this server included", function()
			local bus = Messaging.memoryBus()
			Messaging.configure({ service = bus })
			local name = topicName()
			local Announcements = Messaging.topic(name, Announcement)

			Hydrogen.test({ systems = { Messaging } }, function(t)
				local received: { Announcement } = {}
				local infos: { Hydrogen.MessageInfo } = {}
				Announcements:subscribe(function(value: Announcement, info: Hydrogen.MessageInfo)
					table.insert(received, value)
					table.insert(infos, info)
				end)

				local ok = Announcements:publish({ text = "Double XP!", priority = 2 })
				check.equal(ok, true)
				check.equal(#received, 1)
				check.equal(received[1].text, "Double XP!")
				check.equal(infos[1].fromThisServer, true)
				check.equal(infos[1].serverId, Messaging.serverId())
				check.equal(bus.published[1].topic, name)
				check.equal(bus.published[1].data.v.priority, 2)

				-- From another server.
				bus:send(name, { text = "hello", priority = 1 }, "server-b")
				check.equal(#received, 2)
				check.equal(infos[2].fromThisServer, false)
				check.equal(infos[2].serverId, "server-b")

				-- Subscribers share one frozen copy.
				check.equal(table.isfrozen(received[1] :: any), true)
				t:expectNoWarnings()
			end)
			return nil
		end)

		test.case("is lazy: nothing subscribes until the first subscriber, and topics share one subscription", function()
			local bus = Messaging.memoryBus()
			Messaging.configure({ service = bus })
			local name = topicName()
			local Topic = Messaging.topic(name, gt.string())

			Hydrogen.test({ systems = { Messaging } }, function(_t)
				check.equal(bus:subscribeCalls(), 0)
				local first = Topic:subscribe(function() end)
				local second = Topic:subscribe(function() end)
				check.equal(bus:subscribeCalls(name), 1)
				check.equal(bus:subscriptions(name), 1)

				first()
				check.equal(bus:subscriptions(name), 1)
				second()
				check.equal(bus:subscriptions(name), 0)
				second() -- twice is fine
			end)
			return nil
		end)

		test.case("publish rejects values that fail the schema, before sending", function()
			local bus = Messaging.memoryBus()
			Messaging.configure({ service = bus })
			local Announcements = Messaging.topic(topicName(), Announcement)

			Hydrogen.test({ systems = { Messaging } }, function(_t)
				local message = errorOf(function()
					Announcements:publish({ text = "hi", priority = 1.5 } :: any)
				end)
				check.equal(contains(message, "can't publish a value that doesn't match the schema"), true)
				check.equal(#bus.published, 0)
			end)
			return nil
		end)

		test.case("received values that fail the schema are dropped, with a rate-limited warning", function()
			local bus = Messaging.memoryBus()
			Messaging.configure({ service = bus })
			local name = topicName()
			local Announcements = Messaging.topic(name, Announcement)

			Hydrogen.test({ systems = { Messaging } }, function(t)
				local received = 0
				Announcements:subscribe(function()
					received += 1
				end)

				bus:send(name, { text = 5, priority = 1 })
				check.equal(received, 0)
				t:expectWarning(`Messaging topic {name} dropped a message: it doesn't match the topic's schema`)
				check.equal(#t:warnings(), 1)

				bus:send(name, { text = "x" })
				bus:sendRaw(name, "not an envelope")
				check.equal(#t:warnings(), 1)

				t:advance(10)
				bus:sendRaw(name, { hello = true })
				check.equal(#t:warnings(), 2)
				t:expectWarning("no envelope) (2 more dropped since the last warning)")

				bus:send(name, { text = "fine", priority = 3 })
				check.equal(received, 1)
			end)
			return nil
		end)

		test.case("publish refuses oversize and non-JSON payloads with a fix", function()
			local bus = Messaging.memoryBus()
			Messaging.configure({ service = bus })
			local Text = Messaging.topic(topicName(), gt.string())
			local Points = Messaging.topic(topicName(), gt.table({ at = gt.any() }))

			Hydrogen.test({ systems = { Messaging } }, function(_t)
				local big = errorOf(function()
					Text:publish(string.rep("x", 1000))
				end)
				check.equal(contains(big, "over MessagingService's 1000-byte limit"), true)
				check.equal(contains(big, "send ids and look the rest up"), true)

				local vector = errorOf(function()
					Points:publish({ at = Vector3.new(1, 2, 3) })
				end)
				check.equal(contains(vector, "the value.at is a Vector3"), true)

				-- Just under the limit is fine.
				check.equal(Text:publish(string.rep("x", 900)), true)
				check.equal(#bus.published, 1)
			end)
			return nil
		end)

		test.case("retries a failed publish with backoff", function()
			local bus = Messaging.memoryBus()
			Messaging.configure({ service = bus })
			local Topic = Messaging.topic(topicName(), gt.number())

			Hydrogen.test({ systems = { Messaging } }, function(t)
				bus:failPublishes(2)
				local result: boolean? = nil
				task.spawn(function()
					result = Topic:publish(1)
				end)
				check.equal(result, nil)
				t:advance(1)
				check.equal(result, nil)
				t:advance(2)
				check.equal(result, true)
				check.equal(#bus.published, 1)
				t:expectNoWarnings()
			end)
			return nil
		end)

		test.case("a publish that keeps failing returns false and warns", function()
			local bus = Messaging.memoryBus()
			Messaging.configure({ service = bus })
			local name = topicName()
			local Topic = Messaging.topic(name, gt.number())

			Hydrogen.test({ systems = { Messaging } }, function(t)
				bus:failPublishes(3, "MessagingService is down")
				local ok: boolean? = nil
				local err: string? = nil
				task.spawn(function()
					ok, err = Topic:publish(1)
				end)
				t:advance(1)
				t:advance(2)
				check.equal(ok, false)
				check.equal(err, "MessagingService is down")
				t:expectWarning(`Messaging couldn't publish to topic {name}: MessagingService is down`)
			end)
			return nil
		end)

		test.case("waits when this server would pass the publish rate limit", function()
			local bus = Messaging.memoryBus()
			Messaging.configure({ service = bus })
			local Topic = Messaging.topic(topicName(), gt.number())

			Hydrogen.test({ systems = { Messaging } }, function(t)
				for index = 1, 600 do
					Topic:publish(index)
				end
				local done = false
				task.spawn(function()
					Topic:publish(601)
					done = true
				end)
				check.equal(done, false)
				check.equal(#bus.published, 600)
				t:advance(60)
				check.equal(done, true)
				check.equal(#bus.published, 601)
			end)
			return nil
		end)

		test.case("ignoreSelf skips this server's own messages", function()
			local bus = Messaging.memoryBus()
			Messaging.configure({ service = bus })
			local name = topicName()
			local Topic = Messaging.topic(name, gt.string(), { ignoreSelf = true })

			Hydrogen.test({ systems = { Messaging } }, function(_t)
				local received: { string } = {}
				Topic:subscribe(function(value: string)
					table.insert(received, value)
				end)
				Topic:publish("mine")
				bus:send(name, "theirs", "server-b")
				check.equal(#received, 1)
				check.equal(received[1], "theirs")
			end)
			return nil
		end)

		test.case("subscriptions are dropped on app:stop and with their scope", function()
			local bus = Messaging.memoryBus()
			Messaging.configure({ service = bus })
			local name = topicName()
			local Topic = Messaging.topic(name, gt.string())
			local scoped = topicName()
			local Scoped = Messaging.topic(scoped, gt.string())

			Hydrogen.test({ systems = { Messaging } }, function(_t)
				local scope = Scope.new("round")
				local received = 0
				scope:add(Scoped:subscribe(function()
					received += 1
				end))
				check.equal(bus:subscriptions(scoped), 1)
				scope:destroy()
				check.equal(bus:subscriptions(scoped), 0)
				bus:send(scoped, "late")
				check.equal(received, 0)

				Topic:subscribe(function() end)
				check.equal(bus:subscriptions(name), 1)
			end)
			-- The harness stopped the app.
			check.equal(bus:subscriptions(), 0)
			return nil
		end)

		test.case("retries a failed subscribe in the background", function()
			local bus = Messaging.memoryBus()
			Messaging.configure({ service = bus })
			local name = topicName()
			local Topic = Messaging.topic(name, gt.string())

			Hydrogen.test({ systems = { Messaging } }, function(t)
				bus:failSubscribes(1)
				local received: { string } = {}
				Topic:subscribe(function(value: string)
					table.insert(received, value)
				end)
				check.equal(bus:subscriptions(name), 0)
				t:expectWarning(`Messaging couldn't subscribe to topic {name} (attempt 1), retrying in 1s`)
				t:advance(1)
				check.equal(bus:subscriptions(name), 1)
				bus:send(name, "after")
				check.equal(received[1], "after")
			end)
			return nil
		end)

		test.case("unsubscribing while the subscribe is still retrying leaves nothing subscribed", function()
			local bus = Messaging.memoryBus()
			Messaging.configure({ service = bus })
			local name = topicName()
			local Topic = Messaging.topic(name, gt.string())

			Hydrogen.test({ systems = { Messaging } }, function(t)
				bus:failSubscribes(1)
				local unsubscribe = Topic:subscribe(function() end)
				unsubscribe()
				t:advance(1)
				check.equal(bus:subscriptions(name), 0)
				check.equal(bus:subscribeCalls(name), 1)
				t:expectWarning("couldn't subscribe")
			end)
			return nil
		end)

		test.case("a failing subscriber is warned and the others still run", function()
			local bus = Messaging.memoryBus()
			Messaging.configure({ service = bus })
			local name = topicName()
			local Topic = Messaging.topic(name, gt.string())

			Hydrogen.test({ systems = { Messaging } }, function(t)
				local ran = false
				Topic:subscribe(function()
					error("boom")
				end)
				Topic:subscribe(function()
					ran = true
				end)
				Topic:publish("go")
				check.equal(ran, true)
				t:expectWarning(`Messaging topic {name} subscriber failed`)
			end)
			return nil
		end)

		test.case("configure moves existing subscriptions to the new service", function()
			local first = Messaging.memoryBus()
			Messaging.configure({ service = first })
			local name = topicName()
			local Topic = Messaging.topic(name, gt.string())

			Hydrogen.test({ systems = { Messaging } }, function(_t)
				local received: { string } = {}
				Topic:subscribe(function(value: string)
					table.insert(received, value)
				end)
				local second = Messaging.memoryBus()
				Messaging.configure({ service = second })
				check.equal(first:subscriptions(name), 0)
				check.equal(second:subscriptions(name), 1)
				first:send(name, "old")
				second:send(name, "new")
				check.equal(#received, 1)
				check.equal(received[1], "new")
			end)
			return nil
		end)

		test.case("definition errors say how to fix the call", function()
			local name = topicName()
			Messaging.topic(name, gt.string())
			check.equal(contains(errorOf(function()
				Messaging.topic(name, gt.string())
			end), "is already defined"), true)
			check.equal(contains(errorOf(function()
				Messaging.topic(string.rep("a", 81), gt.string())
			end), "name of 1 to 80 characters"), true)
			check.equal(contains(errorOf(function()
				Messaging.topic(topicName(), "schema" :: any)
			end), "needs a GreenTea schema"), true)
			check.equal(contains(errorOf(function()
				Messaging.configure({ service = {} :: any })
			end), "service is missing PublishAsync"), true)
			return nil
		end)
	end)
end

-- Roblox Services
local RunService = game:GetService("RunService")
assert(RunService:IsServer(), `This module can only be required on the server!`)

local Players = game:GetService("Players")

-- Requires
local packages = script.Parent.Parent :: Folder

local Logr = require(packages.Logr)
local t = require(packages.t)
local Comm = require(packages.Comm)
local Signal = require(packages.Signal)
local Promise = require(packages.Promise)

-- Types
type ServerMiddlewareFn = (args: { any }) -> (boolean, ...any)

type ServerMiddleware = { ServerMiddlewareFn }

type Middleware = {
	Inbound: ServerMiddleware?,
	Outbound: ServerMiddleware?,
}

type PerServiceMiddleware = { [string]: Middleware }

type ServiceDef = {
	Name: string,
	Client: { [any]: any },
	Middleware: any?,
	[any]: any,
}

type Service = {
	Name: string,
	Client: ServiceClient,
	FluxComm: any,
	[any]: any,
}

type ServiceClient = {
	Server: Service,
	[any]: any,
}

type EnvironmentToGameIds = {
	Production: { number },
	Testing: { number },
}

type FluxOptions = {
	LogLevel: string,
	Middleware: Middleware?,
}

type IncomingFluxOptions = {
	LogLevel: string?,
	Middleware: Middleware?,
}

-- Instances
local fluxRepServiceFolder: Folder = Instance.new("Folder")
fluxRepServiceFolder.Name = "Services"

-- Variables
local DEFAULT_OPTIONS: FluxOptions = {
	LogLevel = "None",
	Middleware = nil,
}

local SIGNAL_MARKER = newproxy(true)
getmetatable(SIGNAL_MARKER).__tostring = function()
	return "SIGNAL_MARKER"
end

local PROPERTY_MARKER = newproxy(true)
getmetatable(PROPERTY_MARKER).__tostring = function()
	return "PROPERTY_MARKER"
end

local Component = require(script.Parent.Component)

local FluxLogger = Logr.new("FluxServer", DEFAULT_OPTIONS.LogLevel)

local isInitializing: boolean = false
local isInitalized: boolean = false
local onInitializedComplete: BindableEvent = Instance.new("BindableEvent")

local isStarting: boolean = false
local isStarted: boolean = false
local onStartedComplete: BindableEvent = Instance.new("BindableEvent")

local componentRegistry: { [string]: any } = {}

local loggerRegistry = {}

local services: { [string]: Service } = {}

local selectedOptions: FluxOptions = DEFAULT_OPTIONS

local tFluxOptions = t.strictInterface({
	ServicePromises = t.optional(t.boolean),
	LogLevel = t.optional(t.valueOf(Logr:GetLogLevels())),
	Middleware = t.optional(t.strictInterface({
		Inbound = t.optional(t.array(t.callback)),
		Outbound = t.optional(t.array(t.callback)),
	})),
	PerServiceMiddleware = t.optional(t.map(
		t.string,
		t.strictInterface({
			Inbound = t.optional(t.array(t.callback)),
			Outbound = t.optional(t.array(t.callback)),
		})
	)),
})

------------------------------------------------------------

local FluxServer = {}

-- Current Game Version
FluxServer.GameVersion = nil :: string?

-- Is the game running?
FluxServer.IsStudio = RunService:IsRunning() :: boolean
-- Is this in Studio?
FluxServer.IsStudio = RunService:IsStudio() :: boolean
-- Is this the Server?
FluxServer.IsServer = RunService:IsServer() :: boolean
-- Is this the Client?
FluxServer.IsClient = RunService:IsClient() :: boolean

-- Are we in a production environment?
FluxServer.IsProduction = false :: boolean
-- Are we in a public testing environment?
FluxServer.IsTesting = false :: boolean
-- Are we in a development environment? (Not production or testing)
FluxServer.IsDevelopment = false :: boolean

-- Create a new Signal
function FluxServer.CreateSignal()
	return Signal.new()
end

local function CreateBenchmarkTime(startTime: number): string
	return `{math.floor((os.clock() - startTime) * 1000)} ms`
end

local function InjectIntoTable(targetTable, tableToInject)
	for index, value in tableToInject do
		targetTable[index] = value
	end
end

local tDoesServiceExist = t.tuple(t.string)
local function DoesServiceExist(serviceName: string): boolean
	assert(tDoesServiceExist(serviceName))

	local service: Service? = services[serviceName]
	return service ~= nil and not service._temporaryService
end

local function IsComponentLike(component: any): (boolean, string)
	return t.interface({
		Tag = t.string,
		Construct = t.callback,
		Start = t.callback,
		Stop = t.callback,
	})(component)
end

local function CreateTemporaryService(serviceName: string): {}
	local temporaryService = {
		Name = serviceName,
		_temporaryService = true,
	}
	temporaryService.Client = { Server = temporaryService }

	services[serviceName] = temporaryService
	return temporaryService
end

local function ComponentExists(tag: string): boolean
	return componentRegistry[tag] ~= nil
end

local tGetLogger = t.tuple(t.string, t.optional(t.valueOf(Logr:GetLogLevels())))
function FluxServer.GetLogger(name: string, logLevel: string?)
	assert(tGetLogger(name, logLevel))

	if loggerRegistry[name] then
		return loggerRegistry[name]
	end

	local logger = Logr.new(name, logLevel)
	loggerRegistry[name] = logger

	return logger
end

local tSetLogLevel = t.tuple(t.valueOf(Logr:GetLogLevels()))
function FluxServer.SetLogLevel(level: string)
	assert(tSetLogLevel(level))

	FluxLogger:SetLogLevel(level)
end

function FluxServer.GetComponentFromTag(tag: string)
	return componentRegistry[tag]
end

local tWaitForComponentFromTag = t.tuple(t.Instance, t.string, t.optional(t.number))
function FluxServer.WaitForComponentFromInstanceAndTag(instance: Instance, tag: string, timeout: number?)
	assert(tWaitForComponentFromTag(instance, tag, timeout))

	local component = FluxServer.GetComponentFromTag(tag)
	if not component then
		return Promise.reject()
	end

	return component:WaitForInstance(instance, timeout)
end

local tGetcomponentFromInstanceAndTag = t.tuple(t.Instance, t.string)
function FluxServer.GetComponentFromInstanceAndTag(instance: Instance, tag: string)
	assert(tGetcomponentFromInstanceAndTag(instance, tag))

	local component = FluxServer.GetComponentFromTag(tag)
	if not component then
		return nil
	end

	return component:FromInstance(instance)
end

local tAddComponent = t.tuple(t.instanceIsA("ModuleScript"))
function FluxServer.AddComponent(component: ModuleScript)
	assert(tAddComponent(component))

	local requireStartTime: number = os.clock()
	FluxLogger:Debug(`AddComponent: Requiring {component.Name}`)

	local requiredComponent: any? = require(component)
	FluxLogger:Debug(`AddComponent: Required {CreateBenchmarkTime(requireStartTime)}`)

	local finalStartTime: number = os.clock()
	if not IsComponentLike(requiredComponent) then
		FluxLogger:Debug(
			`AddComponent: {component:GetFullName()} is not a Component! {CreateBenchmarkTime(finalStartTime)})`
		)
		return
	end

	assert(
		not ComponentExists(requiredComponent.Tag),
		`A Component with the tag "{requiredComponent.Tag}" already exists`
	)

	componentRegistry[requiredComponent.Tag] = requiredComponent
	FluxLogger:Debug(`AddComponent: Successfully added {CreateBenchmarkTime(finalStartTime)}`)

	return requiredComponent
end

function FluxServer.CreateComponent(component)
	return Component.new(component)
end

local tAddComponents = t.tuple(t.Instance, t.optional(t.boolean))
function FluxServer.AddComponents(directory: Instance, deep: boolean?)
	assert(tAddComponents(directory, deep))

	local addedControllers = {}
	for _, child: Instance in directory:GetChildren() do
		if child:IsA("ModuleScript") then
			FluxServer.AddComponent(child)
		end

		if deep and child:IsA("Folder") then
			FluxServer.AddComponents(child, deep)
		end
	end

	return addedControllers
end

function FluxServer.CreateService(serviceDef: ServiceDef): Service
	assert(type(serviceDef) == "table", "Service must be a table; got " .. type(serviceDef))
	assert(type(serviceDef.Name) == "string", "Service.Name must be a string; got " .. type(serviceDef.Name))
	assert(#serviceDef.Name > 0, "Service.Name must be a non-empty string")
	assert(not DoesServiceExist(serviceDef.Name), `A Service named "{serviceDef.Name}" already exists`)

	local service = services[serviceDef.Name] or {}
	service._temporaryService = nil
	service.FluxComm = Comm.ServerComm.new(fluxRepServiceFolder, serviceDef.Name)

	InjectIntoTable(service, serviceDef)

	if type(service.Client) ~= "table" then
		service.Client = { Server = service }
	else
		if service.Client.Server ~= service then
			service.Client.Server = service
		end
	end

	services[service.Name] = service

	return service
end

local tAddServices = t.tuple(t.Instance, t.optional(t.boolean))
function FluxServer.AddServices(directory: Instance, deep: boolean?): { Service }
	assert(tAddServices(directory, deep))

	local addedServices = {}
	for _, child: Instance in directory:GetChildren() do
		if child:IsA("ModuleScript") then
			local startTime: number = os.clock()
			FluxLogger:Debug(`AddServices: Requiring {child.Name}`)
			table.insert(addedServices, require(child))
			FluxLogger:Debug(`AddServices: Required {child.Name} in {CreateBenchmarkTime(startTime)}`)
		end

		if deep and child:IsA("Folder") then
			FluxServer.AddServices(child, deep)
		end
	end

	return addedServices
end

local tGetService = t.tuple(t.string)
function FluxServer.GetService(serviceName: string): Controller
	assert(tGetService(serviceName))

	local startTime: number = os.clock()
	FluxLogger:Debug(`GetService: Getting {serviceName}`)

	local service = services[serviceName]
	if not service and not isStarted then
		service = CreateTemporaryService(serviceName)
		FluxLogger:Debug(`GetService: Created temporary Service for {serviceName}`)
	end

	assert(service, `Could not find a Service named "{serviceName}". Verify a Service with this name exists.`)

	FluxLogger:Debug(`GetService: Got {serviceName} in {CreateBenchmarkTime(startTime)}`)

	return service
end

function FluxServer.CreateRemoteSignal()
	return SIGNAL_MARKER
end

function FluxServer.CreateRemoteProperty(initialValue: any)
	return { PROPERTY_MARKER, initialValue }
end

local tInitialize = t.tuple(t.optional(tFluxOptions))
function FluxServer.Initialize(options: IncomingFluxOptions?)
	assert(tInitialize(options))

	if isInitalized or isInitializing then
		return
	end
	isInitializing = true

	-- Setup the options
	selectedOptions = (options or DEFAULT_OPTIONS) :: FluxOptions
	for defaultName, defaultValue in DEFAULT_OPTIONS do
		selectedOptions[defaultName] = if selectedOptions[defaultName] == nil
			then defaultValue
			else selectedOptions[defaultName]
	end

	if selectedOptions.LogLevel then
		FluxServer.SetLogLevel(selectedOptions.LogLevel)
	end

	isInitalized = true
	isInitializing = false

	onInitializedComplete:Fire()
	task.defer(onInitializedComplete.Destroy, onInitializedComplete)
end

function FluxServer.Start()
	if isStarted or isStarting then
		return
	end
	isStarting = true

	if not isInitalized then
		FluxLogger:Debug(`Waiting for Flux to be initialized..`)
		onInitializedComplete.Event:Wait()
	end

	-- Bind Remotes:
	local fluxMiddleware: Middleware = selectedOptions.Middleware or {}
	for _, service in services do
		local middleware = service.Middleware or {}
		local inbound = middleware.Inbound or fluxMiddleware.Inbound
		local outbound = middleware.Outbound or fluxMiddleware.Outbound
		service.Middleware = nil

		for k, v in service.Client do
			if type(v) == "function" then
				service.FluxComm:WrapMethod(service.Client, k, inbound, outbound)
			elseif v == SIGNAL_MARKER then
				service.Client[k] = service.FluxComm:CreateSignal(k, inbound, outbound)
			elseif type(v) == "table" and v[1] == PROPERTY_MARKER then
				service.Client[k] = service.FluxComm:CreateProperty(k, v[2], inbound, outbound)
			end
		end
	end

	-- Check for any temporary controllers
	for serviceName, service: Service in services do
		if service._temporaryService then
			error(`Service named "{serviceName}" was required but nevered created.`)
		end
	end

	-- Initialize the services
	for _, service: Service in services do
		if t.callback(service.FluxInit) then
			service:FluxInit()
		end
	end

	-- Start components
	for _, component in componentRegistry do
		task.defer(component.Activate, component)
	end

	-- Start the services
	for _, service: Service in services do
		if t.callback(service.FluxStart) then
			task.spawn(service.FluxStart, service)
		end

		if t.callback(service.FluxHeartbeat) then
			RunService.Heartbeat:Connect(function(...)
				service:FluxHeartbeat(...)
			end)
		end

		if t.callback(service.FluxStepped) then
			RunService.Stepped:Connect(function(...)
				service:FluxStepped(...)
			end)
		end

		if t.callback(service.FluxPlayerAdded) then
			Players.PlayerAdded:Connect(function(...)
				service:FluxPlayerAdded(...)
			end)

			for _, player: Player in Players:GetPlayers() do
				task.defer(service.FluxPlayerAdded, service, player)
			end
		end

		if t.callback(service.FluxPlayerRemoving) then
			Players.PlayerRemoving:Connect(function(...)
				service:FluxPlayerRemoving(...)
			end)
		end
	end

	isStarted = true
	isStarting = false

	onStartedComplete:Fire()
	task.defer(onStartedComplete.Destroy, onStartedComplete)

	fluxRepServiceFolder.Parent = script.Parent
end

return FluxServer

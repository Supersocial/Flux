-- Roblox Services
local RunService = game:GetService("RunService")
assert(RunService:IsClient(), `This module can only be required on the client!`)

local Players = game:GetService("Players")

-- Requires
local packages = script.Parent.Parent :: Folder

local Logr = require(packages.Logr)
local t = require(packages.t)
local Comm = require(packages.Comm)
local Signal = require(packages.Signal)
local Promise = require(packages.Promise)

-- Types
type ClientMiddlewareFn = (args: { any }) -> (boolean, ...any)

type ClientMiddleware = { ClientMiddlewareFn }

type Middleware = {
	Inbound: ClientMiddleware?,
	Outbound: ClientMiddleware?,
}

type PerServiceMiddleware = { [string]: Middleware }

type ControllerDef = {
	Name: string,
	[any]: any,
}

type Controller = {
	Name: string,
	[any]: any,
}

type Service = {
	[any]: any,
}

type EnvironmentToGameIds = {
	Production: { number },
	Testing: { number },
}

type FluxOptions = {
	ServicePromises: boolean,
	LogLevel: string?,
	Middleware: Middleware?,
	PerServiceMiddleware: PerServiceMiddleware,
}

type IncomingFluxOptions = {
	ServicePromises: boolean,
	LogLevel: string?,
	Middleware: Middleware?,
	PerServiceMiddleware: PerServiceMiddleware?,
}

-- Variables
local DEFAULT_OPTIONS: FluxOptions = {
	ServicePromises = true,
	LogLevel = "None",
	Middleware = nil,
	PerServiceMiddleware = {},
}

local Component = require(script.Parent.Component)

local FluxLogger = Logr.new("FluxClient", DEFAULT_OPTIONS.LogLevel)

local isInitializing: boolean = false
local isInitalized: boolean = false
local onInitializedComplete: BindableEvent = Instance.new("BindableEvent")

local isStarting: boolean = false
local isStarted: boolean = false
local onStartedComplete: BindableEvent = Instance.new("BindableEvent")

local componentRegistry: { [string]: any } = {}

local loggerRegistry = {}

local controllers: { [string]: Controller } = {}
local services: { [string]: Service } = {}
local servicesFolder: Folder? = nil

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

local FluxClient = {}

-- Local Player
FluxClient.LocalPlayer = Players.LocalPlayer

-- Local Player's Gui
FluxClient.PlayerGui = FluxClient.LocalPlayer:WaitForChild("PlayerGui")

-- Is the game running?
FluxClient.IsStudio = RunService:IsRunning() :: boolean
-- Is this in Studio?
FluxClient.IsStudio = RunService:IsStudio() :: boolean
-- Is this the Server?
FluxClient.IsServer = RunService:IsServer() :: boolean
-- Is this the Client?
FluxClient.IsClient = RunService:IsClient() :: boolean

-- Create a new Signal
function FluxClient.CreateSignal()
	return Signal.new()
end

local function CreateBenchmarkTime(startTime: number): string
	return `{math.floor((os.clock() - startTime) * 1000)} ms`
end

local function GetServicesFolder(): Folder
	if not servicesFolder then
		servicesFolder = script.Parent:WaitForChild("Services")
	end
	return servicesFolder :: Folder
end

local function GetMiddlewareForService(serviceName: string): Middleware
	local fluxMiddleware: Middleware = selectedOptions.Middleware or {}
	local serviceMiddleware: Middleware? = selectedOptions.PerServiceMiddleware[serviceName]
	return serviceMiddleware or fluxMiddleware
end

local function BuildService(serviceName: string)
	if services[serviceName] then
		return services[serviceName]
	end

	local middleware: Middleware = GetMiddlewareForService(serviceName)
	local folder: Folder = GetServicesFolder()
	local clientComm = Comm.ClientComm.new(folder, selectedOptions.ServicePromises, serviceName)
	local service = clientComm:BuildObject(middleware.Inbound, middleware.Outbound)
	services[serviceName] = service

	return service
end

local function InjectIntoTable(targetTable, tableToInject)
	for index, value in tableToInject do
		targetTable[index] = value
	end
end

local tDoesControllerExist = t.tuple(t.string)
local function DoesControllerExist(controllerName: string): boolean
	assert(tDoesControllerExist(controllerName))

	local controller: Controller? = controllers[controllerName]
	return controller ~= nil and not controller._temporaryController
end

local function CreateTemporaryController(controllerName: string): Controller?
	if isStarted then
		return nil
	end

	local temporaryController = {
		Name = controllerName,
		_temporaryController = true,
	}
	controllers[controllerName] = temporaryController

	return temporaryController
end

local function IsComponentLike(component: any): (boolean, string)
	return t.interface({
		Tag = t.string,
		new = t.callback,
		Activate = t.callback,
		FromInstance = t.callback,
		WaitForInstance = t.callback,
		GetAll = t.callback,
		Construct = t.callback,
		Start = t.callback,
		Stop = t.callback,
		GetComponent = t.callback,
		Destroy = t.callback,
	})(component)
end

local tGetLogger = t.tuple(t.string, t.optional(t.valueOf(Logr:GetLogLevels())))
function FluxClient.GetLogger(name: string, logLevel: string?)
	assert(tGetLogger(name, logLevel))

	if loggerRegistry[name] then
		return loggerRegistry[name]
	end

	local logger = Logr.new(name, logLevel)
	loggerRegistry[name] = logger

	return logger
end

local tSetLogLevel = t.tuple(t.valueOf(Logr:GetLogLevels()))
function FluxClient.SetLogLevel(level: string)
	assert(tSetLogLevel(level))

	FluxLogger:SetLogLevel(level)
end

local tGetComponentFromTag = t.tuple(t.string)
function FluxClient.GetComponentFromTag(tag: string)
	assert(tGetComponentFromTag(tag))

	local component = componentRegistry[tag]
	if not component and not (isStarted or isStarting) then
		componentRegistry[tag] = {
			_temporaryComponent = true,
		}
	end

	return componentRegistry[tag]
end

local tWaitForComponentFromTag = t.tuple(t.Instance, t.string, t.optional(t.number))
function FluxClient.WaitForComponentFromInstanceAndTag(instance: Instance, tag: string, timeout: number?)
	assert(tWaitForComponentFromTag(instance, tag, timeout))

	local component = FluxClient.GetComponentFromTag(tag)
	if not component then
		return Promise.reject()
	end

	return component:WaitForInstance(instance, timeout)
end

local tGetcomponentFromInstanceAndTag = t.tuple(t.Instance, t.string)
function FluxClient.GetComponentFromInstanceAndTag(instance: Instance, tag: string)
	assert(tGetcomponentFromInstanceAndTag(instance, tag))

	local component = FluxClient.GetComponentFromTag(tag)
	if not component then
		return nil
	end

	return component:FromInstance(instance)
end

function FluxClient.CreateComponent(component)
	local baseTable = componentRegistry[component.Tag]
	assert((not baseTable) or baseTable._temporaryComponent, `Component {component.Tag} already exists!`)
	return Component.new(baseTable or {}, component)
end

local tAddComponent = t.tuple(t.instanceIsA("ModuleScript"))
function FluxClient.AddComponent(component: ModuleScript)
	assert(tAddComponent(component))

	local requireStartTime: number = os.clock()
	FluxLogger:Debug(`AddComponent: Requiring {component.Name}`)

	local requiredComponent = require(component)
	FluxLogger:Debug(`AddComponent: Required {component.Name} in {CreateBenchmarkTime(requireStartTime)}`)

	local finalStartTime: number = os.clock()
	if not IsComponentLike(requiredComponent) then
		FluxLogger:Debug(
			`AddComponent: {component:GetFullName()} is not a Component! {CreateBenchmarkTime(finalStartTime)})`
		)
		return
	end

	requiredComponent._temporaryComponent = nil
	componentRegistry[requiredComponent.Tag] = requiredComponent
	FluxLogger:Debug(`AddComponent: Successfully added {CreateBenchmarkTime(finalStartTime)}`)

	return requiredComponent
end

local tAddComponents = t.tuple(t.Instance, t.optional(t.boolean))
function FluxClient.AddComponents(directory: Instance, deep: boolean?)
	assert(tAddComponents(directory, deep))

	local addedControllers = {}
	for _, child: Instance in directory:GetChildren() do
		if child:IsA("ModuleScript") then
			FluxClient.AddComponent(child)
		end

		if deep and child:IsA("Folder") then
			FluxClient.AddComponents(child, deep)
		end
	end

	return addedControllers
end

function FluxClient.CreateController(controllerDef: ControllerDef): Controller
	assert(type(controllerDef) == "table", "Controller must be a table; got " .. type(controllerDef))
	assert(type(controllerDef.Name) == "string", "Controller.Name must be a string; got " .. type(controllerDef.Name))
	assert(#controllerDef.Name > 0, "Controller.Name must be a non-empty string")
	assert(
		not DoesControllerExist(controllerDef.Name),
		`A Controller named "{controllerDef.Name}" already exists {debug.traceback()}`
	)

	local controller = controllers[controllerDef.Name] or {}
	controller._temporaryController = nil
	InjectIntoTable(controller, controllerDef)
	controllers[controller.Name] = controller

	return controller
end

local tGetService = t.tuple(t.string)
function FluxClient.GetService(serviceName: string): Service
	assert(tGetService(serviceName))

	return BuildService(serviceName)
end

local tAddControllers = t.tuple(t.Instance, t.optional(t.boolean))
function FluxClient.AddControllers(directory: Instance, deep: boolean?): { Controller }
	assert(tAddControllers(directory, deep))

	local addedControllers = {}
	for _, child: Instance in directory:GetChildren() do
		if child:IsA("ModuleScript") then
			local startTime: number = os.clock()
			FluxLogger:Debug(`AddControllers: Requiring {child.Name}`)
			table.insert(addedControllers, require(child))
			FluxLogger:Debug(`AddControllers: Required {child.Name} in {CreateBenchmarkTime(startTime)}`)
		end

		if deep and child:IsA("Folder") then
			FluxClient.AddControllers(child, deep)
		end
	end

	return addedControllers
end

local tGetController = t.tuple(t.string)
function FluxClient.GetController(controllerName: string): Controller
	assert(tGetController(controllerName))

	local startTime: number = os.clock()
	FluxLogger:Debug(`GetController: {controllerName}`)

	local controller = controllers[controllerName]
	if not controller and not isStarted then
		controller = CreateTemporaryController(controllerName)
		FluxLogger:Debug(`GetController: Created temporary Controller for "{controllerName}`)
	end

	assert(
		controller,
		`Could not find a Controller named "{controllerName}". Verify a Controller with this name exists.`
	)

	FluxLogger:Debug(`GetController: Got {controllerName} in {CreateBenchmarkTime(startTime)}`)

	return controller
end

local tInitialize = t.tuple(t.optional(tFluxOptions))
function FluxClient.Initialize(options: IncomingFluxOptions?)
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
		FluxClient.SetLogLevel(selectedOptions.LogLevel)
	end

	isInitalized = true
	isInitializing = false

	onInitializedComplete:Fire()
	task.defer(onInitializedComplete.Destroy, onInitializedComplete)
end

function FluxClient.Start()
	if isStarted or isStarting then
		return
	end
	isStarting = true

	if not isInitalized then
		FluxLogger:Debug(`Waiting for Flux to be initialized..`)
		onInitializedComplete.Event:Wait()
	end

	-- Check for any temporary controllers
	for controllerName, controller: Controller in controllers do
		if controller._temporaryController then
			error(`Controller named "{controllerName}" was required but nevered created.`)
		end
	end

	-- Initialize the controllers
	for _, controller: Controller in controllers do
		if t.callback(controller.FluxInit) then
			controller:FluxInit()
		end
	end

	-- Start components
	for tag: string, component in componentRegistry do
		if component._temporaryComponent then
			error(`Component named "{tag}" was required but never created.`)
		end

		task.defer(component.Activate, component)
	end

	-- Start the controllers
	for _, controller: Controller in controllers do
		if t.callback(controller.FluxStart) then
			task.spawn(controller.FluxStart, controller)
		end

		if t.callback(controller.FluxHeartbeat) then
			RunService.Heartbeat:Connect(function(...)
				controller:FluxHeartbeat(...)
			end)
		end

		if t.callback(controller.FluxStepped) then
			RunService.Stepped:Connect(function(...)
				controller:FluxStepped(...)
			end)
		end

		if t.callback(controller.FluxRenderStepped) then
			RunService.RenderStepped:Connect(function(...)
				controller:FluxRenderStepped(...)
			end)
		end

		if t.callback(controller.FluxCharacterAdded) then
			FluxClient.LocalPlayer.CharacterAdded:Connect(function(...)
				controller:FluxCharacterAdded(...)
			end)

			if FluxClient.LocalPlayer.Character then
				task.defer(controller.FluxCharacterAdded, controller, FluxClient.LocalPlayer.Character)
			end
		end

		if t.callback(controller.FluxPlayerAdded) then
			Players.PlayerAdded:Connect(function(...)
				controller:FluxPlayerAdded(...)
			end)

			for _, player: Player in Players:GetPlayers() do
				task.defer(controller.FluxPlayerAdded, controller, player)
			end
		end

		if t.callback(controller.FluxPlayerRemoving) then
			Players.PlayerRemoving:Connect(function(...)
				controller:FluxPlayerRemoving(...)
			end)
		end
	end

	isStarted = true
	isStarting = false

	onStartedComplete:Fire()
	task.defer(onStartedComplete.Destroy, onStartedComplete)
end

return FluxClient

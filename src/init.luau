local RunService = game:GetService("RunService")

if RunService:IsServer() then
	return require(script.FluxServer)
else
	local fluxServer: Instance? = script:FindFirstChild("FluxServer")
	if fluxServer then
		fluxServer:Destroy()
	end

	return require(script.FluxClient)
end

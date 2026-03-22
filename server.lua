local config = require 'config'

if not config then return end

if config.versionCheck then lib.versionCheck('communityox/ox_fuel') end

local ox_inventory = exports.ox_inventory

local function setFuelState(netId, fuel)
	local vehicle = NetworkGetEntityFromNetworkId(netId)

	if vehicle == 0 or GetEntityType(vehicle) ~= 2 then
		return
	end

	local state = Entity(vehicle)?.state
	fuel = math.clamp(fuel, 0, 100)

	state:set('fuel', fuel, true)
end

---@param playerId number
---@param price number
---@return boolean?
local function defaultPaymentMethod(playerId, price)
	local success = ox_inventory:RemoveItem(playerId, 'money', price)

	if success then return true end

	local money = ox_inventory:GetItemCount(playerId, 'money')

	TriggerClientEvent('ox_lib:notify', playerId, {
		type = 'error',
		description = locale('not_enough_money', price - money)
	})
end

local payMoney = defaultPaymentMethod
local stationProviderResource = 'next-gas-stations'

RegisterNetEvent('ox_fuel:connectStationProvider', function(resourceName)
	local eventSource = tonumber(source) or 0
	if eventSource > 0 then return end
	if type(resourceName) ~= 'string' or resourceName == '' then return end
	if GetResourceState(resourceName) ~= 'started' then return end

	stationProviderResource = resourceName
end)

local function getStationProviderResource()
	if GetResourceState(stationProviderResource) == 'started' then
		return stationProviderResource
	end

	if GetResourceState('next-gas-stations') == 'started' then
		stationProviderResource = 'next-gas-stations'
		return stationProviderResource
	end

	if GetResourceState('next_gas_stations') == 'started' then
		stationProviderResource = 'next_gas_stations'
		return stationProviderResource
	end

	return nil
end

local function getNearbyStationInfo(playerId)
	local providerResource = getStationProviderResource()
	if not providerResource then
		return nil
	end

	local ok, stationInfo = pcall(function()
		return exports[providerResource]:getNearbyStationFuelPrice(playerId)
	end)

	if not ok or type(stationInfo) ~= 'table' then
		return nil
	end

	stationInfo.stationId = tonumber(stationInfo.stationId)
	stationInfo.pricePerLiter = tonumber(stationInfo.pricePerLiter)

	if not stationInfo.stationId or not stationInfo.pricePerLiter or stationInfo.pricePerLiter <= 0 then
		return nil
	end

	return stationInfo
end

local function reportFuelSale(playerId, stationId, liters, totalPrice)
	local providerResource = getStationProviderResource()
	if not providerResource then
		return
	end

	if not stationId or liters <= 0 or totalPrice <= 0 then
		return
	end

	pcall(function()
		exports[providerResource]:reportFuelSale(playerId, stationId, liters, totalPrice)
	end)
end

local function getVehicleLitersFromQuotedPrice(quotedPrice)
	quotedPrice = tonumber(quotedPrice) or 0

	if quotedPrice <= 0 then
		return 0
	end

	local litersPerPriceUnit = (config.refillValue or 0) / (config.priceTick or 1)
	if litersPerPriceUnit <= 0 then
		return 0
	end

	return quotedPrice * litersPerPriceUnit
end

local function getPetrolCanCapacityLiters()
	local durabilityTick = config.durabilityTick or 0
	local refillValue = config.refillValue or 0

	if durabilityTick <= 0 or refillValue <= 0 then
		return 0
	end

	return (100 / durabilityTick) * refillValue
end

exports('setPaymentMethod', function(fn)
	payMoney = fn or defaultPaymentMethod
end)

RegisterNetEvent('ox_fuel:pay', function(price, fuel, netid)
	assert(type(price) == 'number', ('Price expected a number, received %s'):format(type(price)))
	local source = source
	local finalPrice = price
	local stationInfo = getNearbyStationInfo(source)
	local pumpedLiters = 0

	if stationInfo then
		pumpedLiters = getVehicleLitersFromQuotedPrice(price)
		finalPrice = math.max(1, math.ceil(pumpedLiters * stationInfo.pricePerLiter))
	end

	if not payMoney(source, finalPrice) then return end

	fuel = math.floor(fuel)
	setFuelState(netid, fuel)

	if stationInfo then
		reportFuelSale(source, stationInfo.stationId, pumpedLiters, finalPrice)
	end

	TriggerClientEvent('ox_lib:notify', source, {
		type = 'success',
		description = locale('fuel_success', fuel, finalPrice)
	})
end)

RegisterNetEvent('ox_fuel:fuelCan', function(hasCan, price)
	local source = source
	local stationInfo = getNearbyStationInfo(source)
	if hasCan then
		local item = ox_inventory:GetCurrentWeapon(source)
		if not item or item.name ~= 'WEAPON_PETROLCAN' then return end

		local currentDurability = tonumber(item.metadata and item.metadata.durability) or 0
		currentDurability = math.clamp(currentDurability, 0, 100)

		local canCapacityLiters = getPetrolCanCapacityLiters()
		local litersToRefill = canCapacityLiters * ((100 - currentDurability) / 100)
		local finalPrice = price

		if stationInfo then
			finalPrice = math.max(1, math.ceil(litersToRefill * stationInfo.pricePerLiter))
		end

		if not payMoney(source, finalPrice) then return end

		item.metadata.durability = 100
		item.metadata.ammo = 100

		ox_inventory:SetMetadata(source, item.slot, item.metadata)

		if stationInfo then
			reportFuelSale(source, stationInfo.stationId, litersToRefill, finalPrice)
		end

		TriggerClientEvent('ox_lib:notify', source, {
			type = 'success',
			description = locale('petrolcan_refill', finalPrice)
		})
	else
		if not ox_inventory:CanCarryItem(source, 'WEAPON_PETROLCAN', 1) then
			return TriggerClientEvent('ox_lib:notify', source, {
				type = 'error',
				description = locale('petrolcan_cannot_carry')
			})
		end

		local canCapacityLiters = getPetrolCanCapacityLiters()
		local finalPrice = price

		if stationInfo then
			finalPrice = math.max(1, math.ceil(canCapacityLiters * stationInfo.pricePerLiter))
		end

		if not payMoney(source, finalPrice) then return end

		ox_inventory:AddItem(source, 'WEAPON_PETROLCAN', 1)

		if stationInfo then
			reportFuelSale(source, stationInfo.stationId, canCapacityLiters, finalPrice)
		end

		TriggerClientEvent('ox_lib:notify', source, {
			type = 'success',
			description = locale('petrolcan_buy', finalPrice)
		})
	end
end)

RegisterNetEvent('ox_fuel:updateFuelCan', function(durability, netid, fuel)
	local source = source
	local item = ox_inventory:GetCurrentWeapon(source)

	if item and durability > 0 then
		durability = math.floor(item.metadata.durability - durability)
		item.metadata.durability = durability
		item.metadata.ammo = durability

		ox_inventory:SetMetadata(source, item.slot, item.metadata)
		setFuelState(netid, fuel)
	end

	-- player is sus?
end)

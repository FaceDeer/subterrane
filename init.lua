-- caverealms v.0.8 by HeroOfTheWinds
-- original cave code modified from paramat's subterrain
-- For Minetest 0.4.8 stable
-- Depends default
-- License: code WTFPL

subterrane = {} --create a container for functions and constants

--grab a shorthand for the filepath of the mod
local modpath = minetest.get_modpath(minetest.get_current_modname())

--load companion lua files
dofile(modpath.."/nodes.lua")
dofile(modpath.."/functions.lua") --function definitions
dofile(modpath.."/features.lua")
dofile(modpath.."/player_spawn.lua")
dofile(modpath.."/legacy.lua") -- contains old node definitions, will be removed at some point in the future.

subterrane.disable_mapgen_caverns = function()
	local mg_name = minetest.get_mapgen_setting("mg_name")
	local flags_name
	local default_flags
	
	if mg_name == "v7" then 
		flags_name = "mgv7_spflags"
		default_flags = "mountains,ridges,nofloatlands"
	elseif mg_name == "v5" then
		flags_name = "mgv5_spflags"
		default_flags = ""
	else
		return
	end
	
	local function split(source, delimiters)
		local elements = {}
		local pattern = '([^'..delimiters..']+)'
		string.gsub(source, pattern, function(value) elements[#elements + 1] = value; end);
		return elements
	end
	
	local flags_setting = minetest.get_mapgen_setting(flags_name) or default_flags
	local new_flags = {}
	local flags = split(flags_setting, ", ")
	local nocaverns_present = false
	for _, flag in pairs(flags) do
		if flag ~= "caverns" then
			table.insert(new_flags, flag)
		end
		if flag == "nocaverns" then
			nocaverns_present = true
		end
	end
	if not nocaverns_present then
		table.insert(new_flags, "nocaverns")
	end
	minetest.set_mapgen_setting(flags_name, table.concat(new_flags, ","), true)
end

subterrane.disable_mapgen_caverns() -- defaulting to disabling them, for now. Need to assess how to integrate this feature into subterrane better.

local c_lava = minetest.get_content_id("default:lava_source")
local c_obsidian = minetest.get_content_id("default:obsidian")
local c_stone = minetest.get_content_id("default:stone")
local c_air = minetest.get_content_id("air")

subterrane.default_perlin_cave = {
	offset = 0,
	scale = 1,
	spread = {x=256, y=256, z=256},
	seed = -400000000089,
	octaves = 3,
	persist = 0.67
}

subterrane.default_perlin_wave = {
	offset = 0,
	scale = 1,
	spread = {x=512, y=256, z=512}, -- squashed 2:1
	seed = 59033,
	octaves = 6,
	persist = 0.63
}

-- cave_layer_def
--{
--	minimum_depth = -- required, the highest elevation this cave layer will be generated in.
--	maximum_depth = -- required, the lowest elevation this cave layer will be generated in.
--	cave_threshold = -- optional, Cave threshold. Defaults to 0.5. 1 = small rare caves, 0.5 = 1/3rd ground volume, 0 = 1/2 ground volume
--	boundary_blend_range = -- optional, range near ymin and ymax over which caves diminish to nothing. Defaults to 128.
--	perlin_cave = -- optional, a 3D perlin noise definition table to define the shape of the caves
--	perlin_wave = -- optional, a 3D perlin noise definition table that's averaged with the cave noise to add floor strata (squash its spread on the y axis relative to perlin_cave to accomplish this)
--	columns = -- optional, a column_def table for producing truly enormous dripstone formations
--}

-- column_def
--{
--	max_column_radius = -- Maximum radius for individual columns, defaults to 10
--	min_column_radius = -- Minimum radius for individual columns, defaults to 2 (going lower can increase the likelihood of "intermittent" columns with floating sections)
--	node = -- node name to build columns out of. Defaults to default:stone
--	weight = -- a floating point value (usually in the range of 0.5-1) to modify how strongly the column is affected by the surrounding cave. Lower values create a more variable, tapered stalactite/stalagmite combination whereas a value of 1 produces a roughly cylindrical column. Defaults to 0.5
--	maximum_count = -- The maximum number of columns placed in any given column region (each region being a square 4 times the length and width of a map chunk). Defaults to 100
--	minimum_count = -- The minimum number of columns placed in a column region. The actual number placed will be randomly selected between this range. Defaults to 25.
--}

--extra biome properties used by subterrane
--{
--	_subterrane_ceiling_decor = -- function for putting stuff on the ceiling of the big caverns
--	_subterrane_floor_decor =  -- function for putting stuff on the floor of the big caverns
--	_subterrane_fill_node = -- node to fill the cavern with (defaults to air)
--	_subterrane_column_node = -- override the node the giant columns in this biome are made from
--	_subterrane_cave_floor_decor = -- function for putting stuff on the floors of other preexisting open space
--	_subterrane_cave_ceiling_decor = -- function for putting stuff on the ceiling of other preexisting open space
--	_subterrane_mitigate_lava = -- try to patch the walls of big caverns with obsidian plugs when lava intersects. Not perfect, but helpful.
--	_subterrane_override_sea_level = -- Y coordinate where an underground sea level begins. Biomes' y coordinate cutoffs are unreliable underground, this forces subterrane to take this sea level cutoff into account.
--	_subterrane_override_under_sea_biome = -- When below the override_sea_level, the biome with this name will be looked up and substituted.
--	_subterrane_column_node = -- overrides the node type of a cavern layer's column_def, if there are columns here.
--}

local default_column = {
	max_column_radius = 10,
	min_column_radius = 2,
	node = c_stone,
	weight = 0.25,
	maximum_count = 100,
	minimum_count = 25,
}

function subterrane:register_cave_layer(cave_layer_def)

	local YMIN = cave_layer_def.maximum_depth
	local YMAX = cave_layer_def.minimum_depth
	local BLEND = math.min(cave_layer_def.boundary_blend_range or 128, (YMAX-YMIN)/2)
	local TCAVE = cave_layer_def.cave_threshold or 0.5

	local np_cave = cave_layer_def.perlin_cave or subterrane.default_perlin_cave
	local np_wave = cave_layer_def.perlin_wave or subterrane.default_perlin_wave
	
	local yblmin = YMIN + BLEND * 1.5
	local yblmax = YMAX - BLEND * 1.5	
	
	local column_def = cave_layer_def.columns
	local c_column

	if column_def then
		column_def.max_column_radius = column_def.max_column_radius or default_column.max_column_radius
		column_def.min_column_radius = column_def.min_column_radius or default_column.min_column_radius
		c_column = column_def.node or default_column.node
		column_def.weight = column_def.weight or default_column.weight
		column_def.maximum_count = column_def.maximum_count or default_column.maximum_count
		column_def.minimum_count = column_def.minimum_count or default_column.minimum_count
	end
	
	-- On generated function
	minetest.register_on_generated(function(minp, maxp, seed)
		--if out of range of cave definition limits, abort
		if minp.y > YMAX or maxp.y < YMIN then
			return
		end
		
		--easy reference to commonly used values
		local t_start = os.clock()
		local y_max = maxp.y
		local y_min = minp.y
		
		minetest.log("info", "[subterrane] chunk minp " .. minetest.pos_to_string(minp)) --tell people you are generating a chunk
		
		local vm, data, data_param2, area = mapgen_helper.mapgen_vm_data_param2()

		local nvals_cave, cave_area = mapgen_helper.perlin3d("cave", minp, maxp, np_cave) --cave noise for structure
		local nvals_wave = mapgen_helper.perlin3d("wave", minp, maxp, np_wave) --wavy structure of cavern ceilings and floors
		local cave_iterator = cave_area:iterp(minp, maxp)
		
		local biomemap = minetest.get_mapgen_object("biomemap")
		
		--mandatory values
		local sidelen = y_max - y_min + 1 --length of a mapblock

		local column_points = nil
		local column_weight = nil
		if column_def then
			column_points = subterrane.get_scatter_grid(minp, sidelen*4, column_def.minimum_count, column_def.maximum_count)
			column_points = subterrane.prune_points(minp, maxp, column_def.min_column_radius, column_def.max_column_radius, column_points)
			column_weight = column_def.weight
		end

		for vi, x, y, z in area:iterp_xyz(minp, maxp) do
			local index_3d = cave_iterator()
			local index_2d = mapgen_helper.index2d(minp, maxp, x, z)
			
			local tcave --declare variable
			--determine the overall cave threshold
			if y < yblmin then
				tcave = TCAVE + ((yblmin - y) / BLEND) ^ 2
			elseif y > yblmax then
				tcave = TCAVE + ((y - yblmax) / BLEND) ^ 2
			else
				tcave = TCAVE
			end
	
			local biome = mapgen_helper.get_biome_def(biomemap[index_2d])

			if biome and biome._subterrane_override_sea_level and y <= biome._subterrane_override_sea_level then
				local override_name = biome._subterrane_override_under_sea_biome
				if override_name then
					biome = minetest.registered_biomes[override_name]
				else
					biome = nil
				end
			end
			
			local fill_node = c_air
			local column_node = c_column
			if biome then
				if biome._subterrane_fill_node then
					fill_node = biome._subterrane_fill_node
				end
				if biome._subterrane_column_node then
					column_node = biome._subterrane_column_node
				end
			end

			local cave_value = (nvals_cave[index_3d] + nvals_wave[index_3d])/2
			local column_value = 0
			if column_def then
				column_value = subterrane.get_point_heat({x=x, y=y, z=z}, column_points)
			end
			if cave_value > tcave then --if node falls within cave threshold
				if cave_value > tcave then
					if column_value > 0 and cave_value - column_value * column_weight < tcave then
						data[vi] = column_node -- add a column
					else
						data[vi] = fill_node --hollow it out to make the cave
					end
				end
			elseif biome and biome._subterrane_cave_fill_node and data[vi] == c_air then
				data[vi] = biome._subterrane_cave_fill_node
			end
			
			if biome and biome._subterrane_mitigate_lava and cave_value > tcave - 0.1 then -- Eliminate nearby lava to keep it from spilling in
				if data[vi] == c_lava then
					data[vi] = c_obsidian
				end
			end
		end
	
		cave_iterator = cave_area:iterp(minp, maxp) -- reset this iterator
		for vi, x, y, z in area:iterp_xyz(minp, maxp) do
			local index_3d = cave_iterator()
			local index_2d = mapgen_helper.index2d(minp, maxp, x, z)
			
			local ai = vi + area.ystride
			local bi = vi - area.ystride

			local tcave --same as above
			if y < yblmin then
				tcave = TCAVE + ((yblmin - y) / BLEND) ^ 2
			elseif y > yblmax then
				tcave = TCAVE + ((y - yblmax) / BLEND) ^ 2
			else
				tcave = TCAVE
			end
				
			local biome = mapgen_helper.get_biome_def(biomemap[index_2d])
			local fill_node = c_air
			local cave_fill_node = c_air
			
			if biome and biome._subterrane_override_sea_level and y <= biome._subterrane_override_sea_level then
				local override_name = biome._subterrane_override_under_sea_biome
				if override_name then
					biome = minetest.registered_biomes[override_name]
				else
					biome = nil
				end
			end

			if biome then
				local cave_value = (nvals_cave[index_3d] + nvals_wave[index_3d])/2
				-- only check nodes near the edges of caverns
				if math.floor(cave_value*30) == math.floor(tcave*30) then
					if biome._subterrane_fill_node then
						fill_node = biome._subterrane_fill_node
					end					
					--ceiling
					if biome._subterrane_ceiling_decor
						and data[ai] ~= fill_node
						and data[vi] == fill_node
						and y < y_max
						then --ceiling
						biome._subterrane_ceiling_decor(area, data, ai, vi, bi, data_param2)
					end
					--ground
					if biome._subterrane_floor_decor
						and data[bi] ~= fill_node
						and data[vi] == fill_node
						and y > y_min
						then --ground
						biome._subterrane_floor_decor(area, data, ai, vi, bi, data_param2)
					end
					
				elseif cave_value <= tcave then --if node falls outside cave threshold
					-- decorate other "native" caves and tunnels
					if biome._subterrane_cave_fill_node then
						cave_fill_node = biome._subterrane_cave_fill_node
						if data[vi] == c_air then
							data[vi] = cave_fill_node
						end
					end
											
					if biome._subterrane_cave_ceiling_decor
						and data[ai] ~= cave_fill_node
						and data[vi] == cave_fill_node
						and y < y_max
						then --ceiling
						biome._subterrane_cave_ceiling_decor(area, data, ai, vi, bi, data_param2)
					end
					if biome._subterrane_cave_floor_decor
						and data[bi] ~= cave_fill_node
						and data[vi] == cave_fill_node
						and y > y_min
						then --ground
						biome._subterrane_cave_floor_decor(area, data, ai, vi, bi, data_param2)
					end
				end	
			end
		end
		
		--send data back to voxelmanip
		vm:set_data(data)
		vm:set_param2_data(data_param2)
		--calc lighting
		vm:set_lighting({day = 0, night = 0})
		vm:calc_lighting()
		
		vm:update_liquids()
		--write it to world
		vm:write_to_map()
	
		local chunk_generation_time = math.ceil((os.clock() - t_start) * 1000) --grab how long it took
		minetest.log("info", "[subterrane] "..chunk_generation_time.." ms") --tell people how long
	end)
end


function subterrane:register_cave_decor(minimum_depth, maximum_depth)

	-- On generated function
	minetest.register_on_generated(function(minp, maxp, seed)
		--if out of range of cave definition limits, abort
		if minp.y > minimum_depth or maxp.y < maximum_depth then
			return
		end
		
		--easy reference to commonly used values
		local t_start = os.clock()
		local y_max = maxp.y
		local y_min = minp.y
		
		minetest.log("info", "[subterrane] chunk minp " .. minetest.pos_to_string(minp)) --tell people you are generating a chunk
		
		local vm, data, data_param2, area = mapgen_helper.mapgen_vm_data_param2()
		local biomemap = minetest.get_mapgen_object("biomemap")
		
		for vi, x, y, z in area:iterp_xyz(minp, maxp) do
			--decoration loop, places nodes on floor and ceiling
			local index_2d = mapgen_helper.index2d(minp, maxp, x, z)
			local ai = vi + area.ystride
			local bi = vi - area.ystride
		
			local biome = mapgen_helper.get_biome_def(biomemap[index_2d])
			local cave_fill_node = c_air

			if biome then
				-- decorate "native" caves and tunnels
				if biome._subterrane_cave_fill_node then
					cave_fill_node = biome._subterrane_cave_fill_node
					if data[vi] == c_air then
						data[vi] = cave_fill_node
					end
				end

				if biome._subterrane_cave_ceiling_decor
					and data[ai] ~= cave_fill_node
					and data[vi] == cave_fill_node
					and y < y_max
					then --ceiling
					biome._subterrane_cave_ceiling_decor(area, data, ai, vi, bi, data_param2)
				end
				--ground
				if biome._subterrane_cave_floor_decor
					and data[bi] ~= cave_fill_node
					and data[vi] == cave_fill_node
					and y > y_min
					then --ground
					biome._subterrane_cave_floor_decor(area, data, ai, vi, bi, data_param2)
				end
			end	
		end

		
		--send data back to voxelmanip
		vm:set_data(data)
		vm:set_param2_data(data_param2)
		--calc lighting
		vm:set_lighting({day = 0, night = 0})
		vm:calc_lighting()
		--write it to world
		vm:write_to_map()
	
		local chunk_generation_time = math.ceil((os.clock() - t_start) * 1000) --grab how long it took
		minetest.log("info", "[subterrane] "..chunk_generation_time.." ms") --tell people how long
	end)
end

minetest.log("info", "[Subterrane] loaded!")

module("luci.controller.olsr", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/olsrd") then
		return
	end

	require("luci.model.uci")
	local uci = luci.model.uci.cursor_state()

	uci:foreach("olsrd", "olsrd", function(s)
		if s.SmartGateway and s.SmartGateway == "yes" then has_smartgw  = true end
	end)

	local page  = node("admin", "status", "olsr")
	page.target = template("status-olsr/overview")
	page.title  = _("OLSR")
	page.subindex = true

	local page  = node("admin", "status", "olsr", "json")
	page.target = call("action_json")
	page.title = nil
	page.leaf = true

	local page  = node("admin", "status", "olsr", "neighbors")
	page.target = call("action_neigh")
	page.title  = _("Neighbours")
	page.subindex = true
	page.order  = 5

	local page  = node("admin", "status", "olsr", "routes")
	page.target = call("action_routes")
	page.title  = _("Routes")
	page.order  = 10

	local page  = node("admin", "status", "olsr", "topology")
	page.target = call("action_topology")
	page.title  = _("Topology")
	page.order  = 20

	local page  = node("admin", "status", "olsr", "hna")
	page.target = call("action_hna")
	page.title  = _("HNA")
	page.order  = 30

	local page  = node("admin", "status", "olsr", "mid")
	page.target = call("action_mid")
	page.title  = _("MID")
	page.order  = 50

	if has_smartgw then
		local page  = node("admin", "status", "olsr", "smartgw")
		page.target = call("action_smartgw")
		page.title  = _("SmartGW")
		page.order  = 60
	end

	local page  = node("admin", "status", "olsr", "interfaces")
	page.target = call("action_interfaces")
	page.title  = _("Interfaces")
	page.order  = 70

	local ol = entry(
		{"admin", "services", "olsrd"},
		cbi("olsr/olsrd"), "OLSR"
	)
	ol.subindex = true

	entry(
		{"admin", "services", "olsrd", "iface"},
		cbi("olsr/olsrdiface")
	).leaf = true

	entry(
		{"admin", "services", "olsrd", "hna"},
		cbi("olsr/olsrdhna"), _("HNA Announcements")
	)

	oplg = entry(
		{"admin", "services", "olsrd", "plugins"},
		cbi("olsr/olsrdplugins"), _("Plugins")
	)

	odsp = entry(
		{"admin", "services", "olsrd", "display"},
		cbi("olsr/olsrddisplay"), _("Display")
	)

	oplg.leaf = true
	oplg.subindex = true

	local uci = require("luci.model.uci").cursor()
	uci:foreach("olsrd", "LoadPlugin",
		function (section)
			local lib = section.library
			entry(
				{"admin", "services", "olsrd", "plugins", lib },
				cbi("olsr/olsrdplugins"),
				nil --'Plugin "%s"' % lib:gsub("^olsrd_",""):gsub("%.so.+$","")
			)
		end
	)
end

function action_json()
	local http = require "luci.http"
	local utl = require "luci.util"

	local jsonreq4 = utl.exec("echo /status | nc 127.0.0.1 9090")
	local jsonreq6 = utl.exec("echo /status | nc ::1 9090")
	http.prepare_content("application/json")

	if #jsonreq4 < 1 then
		jsonreq4 = "{}"
	end

	if #jsonreq6 < 1 then
		jsonreq6 = "{}"
	end

	http.write("{v4:" .. jsonreq4 .. ", v6:" .. jsonreq6 .. "}")
end

function action_neigh(json)
	local data, has_v4, has_v6, error = fetch_jsoninfo('links')

	if error then
		return
	end

	local uci = require "luci.model.uci".cursor_state()
	local resolve = uci:get("luci_olsr", "general", "resolve")
	local ntm = require "luci.model.network".init()
	local devices  = ntm:get_wifidevs()
	local sys = require "luci.sys"
	local assoclist = {}

	luci.sys.net.routes(function(r) 
		if r.dest:prefix() == 0 then 
			defaultgw = r.gateway:string() 
		end
	end)

	local function compare(a,b)
		if a.proto == b.proto then
			return a.linkCost < b.linkCost
		else
			return a.proto < b.proto
		end
	end

	for _, dev in ipairs(devices) do
		for _, net in ipairs(dev:get_wifinets()) do
			assoclist[#assoclist+1] = {} 
			assoclist[#assoclist]['ifname'] = net.iwdata.ifname
			assoclist[#assoclist]['network'] = net.iwdata.network
			assoclist[#assoclist]['device'] = net.iwdata.device
			assoclist[#assoclist]['list'] = net.iwinfo.assoclist
		end
	end

	for k, v in ipairs(data) do
		local interface
		local snr = 1
		local signal = 1
		local noise = 1
		local arptable = sys.net.arptable()
		local mac
		local rmac
		local lmac
		local ip
		
		if resolve == "1" then
			hostname = nixio.getnameinfo(v.remoteIP, nil, 100)
			if hostname then
				v.hostname = hostname
			end
		end
		if v.proto == '4' then
			uci:foreach("network", "interface",function(vif)
				if vif.ipaddr and vif.ipaddr == v.localIP then
					interface = vif['.name'] or vif.interface
					lmac = string.lower(vif.macaddr or "")
					return
				end
			end)
			for _, arpt in ipairs(arptable) do
				ip = arpt['IP address']
				if ip == v.remoteIP then
					rmac = string.lower(arpt['HW address'] or "")
				end
			end
			for _, val in ipairs(assoclist) do
				if val.network == interface and val.list then
					for assocmac, assot in pairs(val.list) do
						assocmac = string.lower(assocmac or "")
						if rmac == assocmac then
							signal = tonumber(assot.signal)
							noise = tonumber(assot.noise)
							snr = signal/noise
						end
					end
				end
			end
		elseif v.proto == '6' then
			uci:foreach("network", "interface",function(vif)
				if vif.ip6addr and string.gsub(vif.ip6addr, "/64", "") == v.localIP then
					interface = vif['.name'] or vif.interface
					return
				end
			end)
		end
		if interface then
			v.interface = interface
		end
		v.snr = snr
		v.signal = signal
		v.noise = noise
		if rmac then
			v.remoteMAC = rmac
		end
		if lmac then
			v.localMAC = lmac
		end

		if defaultgw == v.remoteIP then
			v.defaultgw = 1
		end
	end

	table.sort(data, compare)
	luci.template.render("status-olsr/neighbors", {links=data, has_v4=has_v4, has_v6=has_v6})
end

function action_routes()
	local data, has_v4, has_v6, error = fetch_jsoninfo('routes')
	if error then
		return
	end

	local uci = require "luci.model.uci".cursor_state()
	local resolve = uci:get("luci_olsr", "general", "resolve")

	for k, v in ipairs(data) do
		if resolve == "1" then
			local hostname = nixio.getnameinfo(v.gateway, nil, 100)
			if hostname then
				v.hostname = hostname
			end
		end
	end

	local function compare(a,b)
		if a.proto == b.proto then
			return a.rtpMetricCost < b.rtpMetricCost
		else
			return a.proto < b.proto
		end
	end

	table.sort(data, compare)
	luci.template.render("status-olsr/routes", {routes=data, has_v4=has_v4, has_v6=has_v6})
end

function action_topology()
	local data, has_v4, has_v6, error = fetch_jsoninfo('topology')
	if error then
		return
	end

	local function compare(a,b)
		if a.proto == b.proto then
			return a.tcEdgeCost < b.tcEdgeCost
		else
			return a.proto < b.proto
		end
	end

	table.sort(data, compare)
	luci.template.render("status-olsr/topology", {routes=data, has_v4=has_v4, has_v6=has_v6})
end

function action_hna()
	local data, has_v4, has_v6, error = fetch_jsoninfo('hna')
	if error then
		return
	end

	local uci = require "luci.model.uci".cursor_state()
	local resolve = uci:get("luci_olsr", "general", "resolve")

	local function compare(a,b)
		if a.proto == b.proto then
			return a.genmask < b.genmask
		else
			return a.proto < b.proto
		end
	end

	for k, v in ipairs(data) do
		if resolve == "1" then
			hostname = nixio.getnameinfo(v.gateway, nil, 100)
			if hostname then
				v.hostname = hostname
			end
		end
		if v.validityTime then
			v.validityTime = tonumber(string.format("%.0f", v.validityTime / 1000))
		end
	end

	table.sort(data, compare)
	luci.template.render("status-olsr/hna", {hna=data, has_v4=has_v4, has_v6=has_v6})
end

function action_mid()
	local data, has_v4, has_v6, error = fetch_jsoninfo('mid')
	if error then
		return
	end

	local function compare(a,b)
		if a.proto == b.proto then
			return a.ipAddress < b.ipAddress
		else
			return a.proto < b.proto
		end
	end

	table.sort(data, compare)
	luci.template.render("status-olsr/mid", {mids=data, has_v4=has_v4, has_v6=has_v6})
end

function action_smartgw()
	local data, has_v4, has_v6, error = fetch_jsoninfo('gateways')
	if error then
		return
	end

	local function compare(a,b)
		if a.proto == b.proto then
			return a.tcPathCost < b.tcPathCost
		else
			return a.proto < b.proto
		end
	end

	table.sort(data, compare)
	luci.template.render("status-olsr/smartgw", {gws=data, has_v4=has_v4, has_v6=has_v6})
end

function action_interfaces()
	local data, has_v4, has_v6, error = fetch_jsoninfo('interfaces')
	if error then
		return
	end

	local function compare(a,b)
		return a.proto < b.proto
	end

	table.sort(data, compare)
	luci.template.render("status-olsr/interfaces", {iface=data, has_v4=has_v4, has_v6=has_v6})
end

-- Internal
function fetch_jsoninfo(otable)
	local uci = require "luci.model.uci".cursor_state()
	local utl = require "luci.util"
	local json = require "luci.json"
	local jsonreq4 = utl.exec("echo /" .. otable .. " | nc 127.0.0.1 9090")
	local jsondata4 = {}
	local jsonreq6 = utl.exec("echo /" .. otable .. " | nc ::1 9090")
	local jsondata6 = {}
	local data4 = {}
	local data6 = {}
	local has_v4 = False
	local has_v6 = False

	if jsonreq4 == '' and jsonreq6 == '' then
		luci.template.render("status-olsr/error_olsr")
		return nil, 0, 0, true
	end

	if #jsonreq4 ~= 0 then
		has_v4 = 1
		jsondata4 = json.decode(jsonreq4)
		if otable == 'status' then
			data4 = jsondata4 or {}
		else
			data4 = jsondata4[otable] or {}
		end

		for k, v in ipairs(data4) do
			data4[k]['proto'] = '4'
		end

	end
	if #jsonreq6 ~= 0 then
		has_v6 = 1
		jsondata6 = json.decode(jsonreq6)
		if otable == 'status' then
			data6 = jsondata6 or {}
		else
			data6 = jsondata6[otable] or {}
		end
		for k, v in ipairs(data6) do
			data6[k]['proto'] = '6'
		end
	end

	for k, v in ipairs(data6) do
		table.insert(data4, v)
	end

	return data4, has_v4, has_v6, false
end


<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
<meta http-equiv="X-UA-Compatible" content="IE=Edge" />
<meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
<meta http-equiv="Pragma" content="no-cache" />
<meta http-equiv="Expires" content="-1" />
<link rel="shortcut icon" href="/res/icon-igmpproxy.png" />
<link rel="icon" href="/res/icon-igmpproxy.png" />
<title>软件中心 - IGMP Proxy</title>
<link rel="stylesheet" type="text/css" href="index_style.css">
<link rel="stylesheet" type="text/css" href="form_style.css">
<link rel="stylesheet" type="text/css" href="usp_style.css">
<link rel="stylesheet" type="text/css" href="css/element.css">
<link rel="stylesheet" type="text/css" href="/res/softcenter.css">
<script language="JavaScript" type="text/javascript" src="/js/jquery.js"></script>
<script language="JavaScript" type="text/javascript" src="/state.js"></script>
<script language="JavaScript" type="text/javascript" src="/general.js"></script>
<script language="JavaScript" type="text/javascript" src="/res/softcenter.js"></script>
<script language="JavaScript" type="text/javascript" src="/help.js"></script>
<style>
a:focus {
	outline: none;
}
.SimpleNote {
	padding:5px 5px;
}
i {
	color: #FC0;
	font-style: normal;
}
.loadingBarBlock{
	width:740px;
}
.popup_bar_bg_ks{
	position:fixed;
	margin: auto;
	top: 0;
	left: 0;
	width:100%;
	height:100%;
	z-index:99;
	filter:alpha(opacity=90);
	background-repeat: repeat;
	visibility:hidden;
	overflow:hidden;
	background:rgba(68, 79, 83, 0.85) none repeat scroll 0 0 !important;
	background-position: 0 0;
	background-size: cover;
	opacity: .94;
}
.FormTitle em {
	color: #00ffe4;
	font-style: normal;
}
.FormTable th {
	width: 30%;
}
.formfonttitle {
	font-family: Roboto-Light, "Microsoft JhengHei";
	font-size: 18px;
	margin-left: 5px;
}
.FormTitle, .FormTable, .FormTable th, .FormTable td, .FormTable thead td, .FormTable_table, .FormTable_table th, .FormTable_table td, .FormTable_table thead td {
	font-size: 14px;
	font-family: Roboto-Light, "Microsoft JhengHei";
}
</style>
<script type="text/javascript">
var dbus = {};
var count_down;
var refresh_flag = 0;
var params_check = ['igmpproxy_quickleave', 'igmpproxy_firewall', 'igmpproxy_rpfilter', 'igmpproxy_watchdog', 'igmpproxy_force'];
var params_input = ['igmpproxy_upstream', 'igmpproxy_downstream', 'igmpproxy_altnet'];
// 首次安装时 dbus 里可能还没有这些键，用与后端一致的默认值渲染（只用于显示，不回写 dbus）
var params_default = {'igmpproxy_quickleave':'1', 'igmpproxy_firewall':'1', 'igmpproxy_rpfilter':'1', 'igmpproxy_watchdog':'1', 'igmpproxy_force':'0'};

// 设置项说明：用固件原生的 helpcontent + openHint 弹窗（呈现方式同 Advanced_LAN_Content.asp）。
// helpcontent 由 /help.js 声明、/help_content.js 异步填充（只占 0~35），这里取没人用的 99。
helpcontent[99] = new Array("",
	"IPTV 信号从哪个口进来。不会选就留空，插件会自动挑一个能用的；拿不准先保持自动，机顶盒开机后可以点「诊断日志」看实际用的是哪个口。",
	"电视信号从哪个口转给家里的设备，一般就是局域网（br0），保持「自动探测」即可。",
	"只转发放行这些地址来的节目流。留空 = 不限制，一般不用填。",
	"换台更快：换台时立刻停掉上一路节目。个别老机顶盒如果出现闪断，就把它关掉。",
	"自动放行 IPTV 需要的流量，防火墙重启后也会自己补回来。建议保持勾选，否则内网设备可能收不到电视信号。",
	"有些节目流会被防火墙当成异常流量丢掉，勾上可以少丢包。电视能正常看就不用管；万一「有信号但黑屏」可以试着勾上。",
	"让程序一直运行：意外退出（比如宽带重拨）后会自动重新启动。建议保持开启。",
	"如果本机已经有一个同样的代理程序在跑，默认不去抢；勾上会先结束旧的，由本插件接管。",
	"状态栏「进程守护」的意思：正常 = 程序在运行，挂了会自动重启；未启用 = 没开「实时进程守护」；待启动 = 已开启但程序还没跑起来；异常 = 守护没生效，可以点「诊断日志」看原因。");

String.prototype.myReplace = function(f, e){
	var reg = new RegExp(f, "g");
	return this.replace(reg, e);
}

function init() {
	show_menu(menu_hook);
	build_hint_links();
	register_event();
	get_dbus_data();
	check_status();
}

function menu_hook(title, tab) {
	tabtitle[tabtitle.length - 1] = new Array("", "IGMP Proxy");
	tablink[tablink.length - 1] = new Array("", "Module_igmpproxy.asp");
}

// 给“设置”面板每个配置项的标签加上可点击的问号说明，
// 弹窗机制与 Advanced_LAN_Content.asp 相同（openHint + helpcontent），说明文本见页面顶部 helpcontent[99]
function build_hint_links(){
	// [控件 id, helpcontent[99] 里的说明序号]；th_daemon 直接就是标签本身（状态栏「进程守护」）
	var hint_map = [
		["igmpproxy_upstream", 1],
		["igmpproxy_downstream", 2],
		["igmpproxy_altnet", 3],
		["igmpproxy_quickleave", 4],
		["igmpproxy_firewall", 5],
		["igmpproxy_rpfilter", 6],
		["igmpproxy_watchdog", 7],
		["igmpproxy_force", 8],
		["th_daemon", 9]
	];
	for (var i = 0; i < hint_map.length; i++) {
		var el = E(hint_map[i][0]);
		if (!el) { continue; }
		var th = null;
		if (el.tagName == "TH") {
			th = el;
		} else {
			var node = el.parentNode;
			while (node && !th) {
				if (node.tagName == "TR" && node.getElementsByTagName) {
					var ths = node.getElementsByTagName("th");
					if (ths.length > 0) { th = ths[0]; }
				}
				node = node.parentNode;
			}
		}
		if (!th) { continue; }
		// 与 Advanced_LAN_Content.asp 完全相同的写法：把标签文字本身变成可点击的说明链接
		th.innerHTML = '<a class="hintstyle" href="javascript:void(0);" onClick="openHint(99,' + hint_map[i][1] + ');">' + th.innerHTML + '</a>';
	}
}

function get_dbus_data(){
	$.ajax({
		type: "GET",
		url: "/_api/igmpproxy_",
		dataType: "json",
		async: false,
		success: function(data) {
			dbus = data.result[0];
			conf2obj();
			show_hide_element();
			show_router_state();
			fill_iface_selects();
		}
	});
}

function conf2obj(){
	for (var i = 0; i < params_check.length; i++) {
		var k = params_check[i];
		if (E(k)) {
			var v = dbus[k];
			if (typeof v == "undefined" || v == null || v == "") {
				v = params_default[k];
			}
			E(k).checked = (v != "0");
		}
	}
	for (var i = 0; i < params_input.length; i++) {
		var k = params_input[i];
		if (E(k) && dbus[k]) {
			$("#" + k).val(dbus[k]);
		}
	}
	// 插件版本号显示在标题后面（取自安装时写入的 dbus）
	if (dbus["igmpproxy_version"] && E("igmpproxy_version")) {
		E("igmpproxy_version").innerHTML = " - " + dbus["igmpproxy_version"];
	}
}

function show_hide_element(){
	if(dbus["igmpproxy_enable"] == "1"){
		E("igmpproxy_apply_1").style.display = "none";
		E("igmpproxy_apply_2").style.display = "";
		E("igmpproxy_apply_0").style.display = "";
	}else{
		E("igmpproxy_apply_1").style.display = "";
		E("igmpproxy_apply_2").style.display = "none";
		E("igmpproxy_apply_0").style.display = "none";
	}
	if (E("igmpproxy_enable")) {
		E("igmpproxy_enable").value = dbus["igmpproxy_enable"] || "0";
	}
}

// 上游 / 下游接口下拉框：候选由后端 ifaces 命令给出（只列当前真有 IPv4 地址的口，
// 没地址的口做不了上下游、后端就不会返回），另有「其它接口」供手动填写
function fill_iface_selects(){
	var id = parseInt(Math.random() * 100000000);
	var postData = {"id": id, "method": "igmpproxy_config.sh", "params": ["ifaces"], "fields": ""};
	$.ajax({
		type: "POST",
		url: "/_api/",
		async: false,
		data: JSON.stringify(postData),
		dataType: "json",
		success: function(response) {
			// 后端返回 "上游候选|下游候选|自动上游"：主段空格分隔，
			// 第 3 段是留空时实际会用的上游口，用它给「自动探测」加个短注解
			// （文案要短：下拉框会按最长选项撑宽，太长会把下拉框拉得很长）
			var g = String(response.result).split("|");
			var autoUp = "自动探测";
			var pu = (g[2] == null) ? "" : String(g[2]).replace(/^\s+|\s+$/g, "");
			if (pu != "") {
				autoUp = "自动探测（优先 " + pu + "）";
			}
			build_iface_select("igmpproxy_upstream", g[0], autoUp);
			build_iface_select("igmpproxy_downstream", g[1], "自动探测（LAN 接口）");
		},
		error: function(){
			build_iface_select("igmpproxy_upstream", "", "自动探测");
			build_iface_select("igmpproxy_downstream", "", "自动探测（LAN 接口）");
		}
	});
}

var IFACE_CUSTOM = "__custom__";

function build_iface_select(sid, list, autoText){
	var sel = E(sid);
	if (!sel) { return; }
	var saved = (dbus && dbus[sid]) ? dbus[sid] : "";
	var opts = ['<option value="">' + autoText + '</option>'];
	var seen = {};
	var arr = String(list || "").replace(/^\s+|\s+$/g, "").split(/\s+/);
	for (var i = 0; i < arr.length; i++) {
		var v = arr[i];
		if (v == "" || seen[v]) { continue; }
		seen[v] = 1;
		opts.push('<option value="' + v + '">' + v + '</option>');
	}
	opts.push('<option value="' + IFACE_CUSTOM + '">其它接口（手动填写）</option>');
	sel.innerHTML = opts.join("");
	var inp = E(sid + "_custom");
	if (inp) { inp.value = ""; }
	if (saved == "") {
		sel.value = "";
	} else if (seen[saved]) {
		sel.value = saved;
	} else {
		// dbus 里存的接口名不在候选里（换了接线、拨号没起来、或本来就是特殊口）：
		// 落到「其它接口」并把手动输入框填上，避免配置被悄悄改掉
		sel.value = IFACE_CUSTOM;
		if (inp) { inp.value = saved; }
	}
	toggle_iface_custom(sid);
}

// 只有选到「其它接口」时才显示手动输入框
function toggle_iface_custom(sid){
	var sel = E(sid);
	var inp = E(sid + "_custom");
	if (!sel || !inp) { return; }
	inp.style.display = (sel.value == IFACE_CUSTOM) ? "" : "none";
}

// 用户最终想用的接口名：下拉选了「其它接口」就用手动输入的值
function iface_value(sid){
	var sel = E(sid);
	if (!sel) { return ""; }
	if (sel.value == IFACE_CUSTOM) {
		var inp = E(sid + "_custom");
		return inp ? String(inp.value).replace(/^\s+|\s+$/g, "") : "";
	}
	return sel.value;
}

// 固件环境：只看固件自身的「启动组播路由」是否关着（开着就会和本插件抢 IGMP）
// 直接由 ASP 注入 nvram，不额外发请求
function show_router_state(){
	var mr = "<% nvram_get("mr_enable_x"); %>";
	if (mr == "" || mr == "0") {
		E("igmpproxy_router_state").innerHTML = "就绪";
		E("ig_mr_warn").style.display = "none";
	} else {
		E("igmpproxy_router_state").innerHTML = "<span style=\"color:#FC0\">未就绪：固件自身的「启动组播路由」已开启</span>";
		E("ig_mr_warn").style.display = "";
	}
}

function register_event(){
	// 上下游选到「其它接口」时显示手动输入框
	$("#igmpproxy_upstream").change(function(){ toggle_iface_custom("igmpproxy_upstream"); });
	$("#igmpproxy_downstream").change(function(){ toggle_iface_custom("igmpproxy_downstream"); });
	// 弹窗只按倒计时自动关闭：不再有“手动关闭”状态，保证任何情况下都能关掉
	$(window).resize(function(){
		var page_h = window.innerHeight || document.documentElement.clientHeight || document.body.clientHeight;
		var page_w = window.innerWidth || document.documentElement.clientWidth || document.body.clientWidth;
		if($('.popup_bar_bg_ks').css("visibility") == "visible"){
			document.scrollingElement.scrollTop = 0;
			var log_h = E("loadingBarBlock").clientHeight;
			var log_w = E("loadingBarBlock").clientWidth;
			var log_h_offset = (page_h - log_h) / 2;
			var log_w_offset = (page_w - log_w) / 2 + 90;
			$('#loadingBarBlock').offset({top: log_h_offset, left: log_w_offset});
		}
	});
}

function check_status(){
	var id = parseInt(Math.random() * 100000000);
	var postData = {"id": id, "method": "igmpproxy_config.sh", "params": ['status'], "fields": ""};
	$.ajax({
		type: "POST",
		url: "/_api/",
		data: JSON.stringify(postData),
		dataType: "json",
		success: function(response) {
			// 后端用 | 分成三段：运行状态 / 组播流向 / 进程守护
			var parts = String(response.result).split("|");
			E("igmpproxy_status").innerHTML = parts[0];
			if (E("igmpproxy_ifaces")) {
				E("igmpproxy_ifaces").innerHTML = (parts.length > 1 && parts[1] != "") ? parts[1] : "未生成配置";
			}
			if (E("igmpproxy_daemon")) {
				E("igmpproxy_daemon").innerHTML = (parts.length > 2 && parts[2] != "") ? parts[2] : "未知";
			}
		},
		error: function(){
			E("igmpproxy_status").innerHTML = "查询失败";
			if (E("igmpproxy_ifaces")) {
				E("igmpproxy_ifaces").innerHTML = "查询失败";
			}
			if (E("igmpproxy_daemon")) {
				E("igmpproxy_daemon").innerHTML = "查询失败";
			}
		}
	});
	setTimeout("check_status();", 10000);
}

function save(flag){
	var db_igmpproxy = {};
	if(flag){
		db_igmpproxy["igmpproxy_enable"] = String(flag);
	}else{
		db_igmpproxy["igmpproxy_enable"] = "0";
	}
	for (var i = 0; i < params_check.length; i++) {
		db_igmpproxy[params_check[i]] = E(params_check[i]).checked ? '1' : '0';
	}
	for (var i = 0; i < params_input.length; i++) {
		if (E(params_input[i])) {
			db_igmpproxy[params_input[i]] = E(params_input[i]).value;
		}
	}
	// 接口项是「下拉框 + 可选的手动输入」，最终值交给 iface_value 决定
	db_igmpproxy["igmpproxy_upstream"] = iface_value("igmpproxy_upstream");
	db_igmpproxy["igmpproxy_downstream"] = iface_value("igmpproxy_downstream");
	var id = parseInt(Math.random() * 100000000);
	var postData = {"id": id, "method": "igmpproxy_config.sh", "params": ["web_submit"], "fields": db_igmpproxy};
	$.ajax({
		type: "POST",
		url: "/_api/",
		data: JSON.stringify(postData),
		dataType: "json",
		success: function(response) {
			if(response.result == id){
				get_log(2);
			}
		}
	});
}

function do_cmd(cmd){
	var id = parseInt(Math.random() * 100000000);
	var postData = {"id": id, "method": "igmpproxy_config.sh", "params": [cmd], "fields": ""};
	$.ajax({
		type: "POST",
		url: "/_api/",
		data: JSON.stringify(postData),
		dataType: "json",
		success: function(response) {
			get_log(0);
		},
		error: function(){
			get_log(0);
		}
	});
}

var log_tries = 0;
var log_timer = null;
// 日志弹窗是否仍处于打开状态：用户提前点关闭后置 0，
// 用来阻止还在进行的轮询 / 收尾逻辑把关闭按钮又显示出来
var log_active = 0;

// 诊断日志：先让后端把当前现场收集进日志文件，再打开弹窗读取
function do_log(){
	var id = parseInt(Math.random() * 100000000);
	var postData = {"id": id, "method": "igmpproxy_config.sh", "params": ["log"], "fields": ""};
	$.ajax({
		type: "POST",
		url: "/_api/",
		data: JSON.stringify(postData),
		dataType: "json",
		success: function(response) { get_log(1); },
		error: function() { get_log(1); }
	});
}

// 打开日志弹窗：先无条件把「自动关闭」按钮和倒计时准备好。
// 这样即使日志文件是空的、或者读取请求一直不返回，弹窗也一定能被关掉
// （旧实现是等到读到结束标记才显示按钮，日志为空时就永远关不掉了）。
function get_log(flag){
	E("log_content").value = "";
	E("loading_block_title").innerHTML = "&nbsp;&nbsp;IGMP Proxy 日志信息";
	showALLoadingBar();
	E("ok_button").style.visibility = "visible";
	if (log_timer) { clearTimeout(log_timer); log_timer = null; }
	log_active = 1;
	count_down = (flag == 1) ? 45 : 20;
	count_down_close();
	log_tries = 0;
	get_log_poll(flag);
}

function get_log_poll(flag){
	// 弹窗已被关闭：停止后续轮询，避免收尾逻辑重新弹出关闭按钮
	if (!log_active) { return false; }
	$.ajax({
		url: '/_temp/igmpproxy_log.txt',
		type: 'GET',
		cache:false,
		dataType: 'text',
		success: function(response) {
			if (!log_active) { return false; }
			var text = "" + response;
			var retArea = E("log_content");
			retArea.value = text.myReplace("IG01P05X", " ");
			retArea.scrollTop = retArea.scrollHeight;
			if (text.search("IG01P05X") != -1) {
				finish_log(flag, 0);
				return false;
			}
			// 等太久（约 45 秒）还没有结束标记：给一段占位说明再收尾，不留空白弹窗
			if (log_tries >= 90) {
				if (retArea.value.replace(/\s/g, "") == "") {
					E("loading_block_title").innerHTML = "&nbsp;&nbsp;暂无日志信息 ...";
					retArea.value = "（还没有日志内容）\n\n可能的原因：\n  1. 插件刚装好，还没有执行过「开启 / 重启 / 关闭」这类会产生日志的操作；\n  2. 日志被清空过。\n\n可先点「开启」或「重启」，再回来看这里。";
				}
				finish_log(flag, 1);
				return false;
			}
			log_tries++;
			setTimeout(function(){ get_log_poll(flag); }, 500);
		},
		error: function(xhr) {
			if (E("log_content").value.replace(/\s/g, "") == "") {
				E("loading_block_title").innerHTML = "&nbsp;&nbsp;暂无日志信息 ...";
				E("log_content").value = "（暂时读不到日志）";
			}
			finish_log(flag, 1);
			return false;
		}
	});
}

// 收尾：只重置剩余阅读时间，倒计时链由 get_log 启动的那一条负责，
// 避免重复启动多条链让「自动关闭（N）」的数字乱跳。
function finish_log(flag, iserror){
	// 用户已经手动关闭了弹窗：不再显示关闭按钮，也不重置倒计时
	if (!log_active) { return false; }
	E("ok_button").style.visibility = "visible";
	if (iserror) {
		refresh_flag = 0;
		count_down = 8;
	} else if (flag == 1) {
		refresh_flag = 0;
		count_down = 20;
	} else {
		refresh_flag = 1;
		count_down = 6;
	}
}

function showALLoadingBar(){
	document.scrollingElement.scrollTop = 0;
	E("loading_block_title").innerHTML = "&nbsp;&nbsp;IGMP Proxy 日志信息";
	E("LoadingBar").style.visibility = "visible";
	var page_h = window.innerHeight || document.documentElement.clientHeight || document.body.clientHeight;
	var page_w = window.innerWidth || document.documentElement.clientWidth || document.body.clientWidth;
	var log_h = E("loadingBarBlock").clientHeight;
	var log_w = E("loadingBarBlock").clientWidth;
	var log_h_offset = (page_h - log_h) / 2;
	var log_w_offset = (page_w - log_w) / 2 + 90;
	$('#loadingBarBlock').offset({top: log_h_offset, left: log_w_offset});
}

function hideALLoadingBar(){
	// 先标记弹窗已关闭并停掉倒计时链，再去隐藏，
	// 这样用户提前点「关闭」后，轮询收尾不会再让按钮跳出来
	log_active = 0;
	if (log_timer) { clearTimeout(log_timer); log_timer = null; }
	count_down = -1;
	E("LoadingBar").style.visibility = "hidden";
	E("ok_button").style.visibility = "hidden";
	if (refresh_flag == "1"){
		if (typeof refreshpage == "function") {
			refreshpage();
		} else {
			location.reload();
		}
	}
}

// 只做倒计时自动关闭：按钮呈现与交互和本插件其它地方的「自动关闭（N）」一致。
// 倒计时到 0 就关闭弹窗；按钮本身也可以直接点击立即关闭（onclick=hideALLoadingBar）。
function count_down_close() {
	if (count_down <= 0) {
		log_timer = null;
		hideALLoadingBar();
		return false;
	}
	E("ok_button1").value = "自动关闭（" + count_down + "）";
	--count_down;
	log_timer = setTimeout(function(){ count_down_close(); }, 1000);
}

</script>
</head>
<body id="app" skin='<% nvram_get("sc_skin"); %>' onload="init();">
	<div id="TopBanner"></div>
	<div id="Loading" class="popup_bg"></div>
	<div id="LoadingBar" class="popup_bar_bg_ks" style="z-index: 201;" >
		<table cellpadding="5" cellspacing="0" id="loadingBarBlock" class="loadingBarBlock" align="center">
			<tr>
				<td height="100">
					<div id="loading_block_title" style="margin:10px auto;margin-left:10px;width:85%; font-size:12pt;"></div>
					<div id="loading_block_spilt" style="margin:10px 0 10px 5px;" class="loading_block_spilt">
						<li><font color="#ffcc00">请等待日志显示完毕，并出现自动关闭按钮！</font></li>
						<li><font color="#ffcc00">在此期间请不要刷新本页面，不然可能导致问题！</font></li>
					</div>
					<div style="margin-left:15px;margin-right:15px;margin-top:10px;outline: 1px solid #3c3c3c;overflow:hidden">
						<textarea cols="50" rows="25" wrap="off" readonly="readonly" id="log_content" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" style="border:1px solid #000;width:99%; font-family:'Lucida Console'; font-size:11px;background:transparent;color:#FFFFFF;outline: none;padding-left:5px;padding-right:22px;overflow-x:hidden"></textarea>
					</div>
					<div id="ok_button" class="apply_gen" style="background:#000;visibility:hidden;">
						<input id="ok_button1" class="button_gen" type="button" onclick="hideALLoadingBar()" value="确定">
					</div>
				</td>
			</tr>
		</table>
	</div>
	<!--=============================================================================================================-->
	<table class="content" align="center" cellpadding="0" cellspacing="0">
		<tr>
			<td width="17">&nbsp;</td>
			<td valign="top" width="202">
				<div id="mainMenu"></div>
				<div id="subMenu"></div>
			</td>
			<td valign="top">
				<div id="tabMenu" class="submenuBlock"></div>
				<table width="98%" border="0" align="left" cellpadding="0" cellspacing="0">
					<tr>
						<td align="left" valign="top">
							<table width="760px" border="0" cellpadding="5" cellspacing="0" bordercolor="#6b8fa3" class="FormTitle" id="FormTitle">
								<tr>
									<td bgcolor="#4D595D" colspan="3" valign="top">
										<div>&nbsp;</div>
										<div class="formfonttitle">IGMP Proxy<lable id="igmpproxy_version"></lable></div>
										<div style="float: right; width: 15px; height: 25px; margin-top: -20px">
											<img id="return_btn" alt="" onclick="reload_Soft_Center();" align="right" style="cursor: pointer; position: absolute; margin-left: -30px; margin-top: -25px;" title="返回软件中心" src="/images/backprev.png" onmouseover="this.src='/images/backprevclick.png'" onmouseout="this.src='/images/backprev.png'" />
										</div>
										<div style="margin: 10px 0 10px 5px;" class="splitLine"></div>
										<div class="SimpleNote">
											IGMP 组播代理：接管固件自带的 <em>igmpproxy</em>，把运营商 IPTV 的组播流量转发进内网
											<span><a type="button" class="ks_btn" href="javascript:void(0);" onclick="do_log()" style="margin-left:5px;">诊断日志</a></span>
										</div>
										<div id="igmpproxy_status_pannel">
											<table width="100%" border="1" align="center" cellpadding="4" cellspacing="0" bordercolor="#6b8fa3" class="FormTable">
												<thead>
													<tr>
														<td colspan="2">IGMP Proxy - 状态</td>
													</tr>
												</thead>
												<tr id="ig_status">
													<th>运行状态</th>
													<td>
														<span style="margin-left:4px" id="igmpproxy_status">查询中...</span>
													</td>
												</tr>
												<tr id="ig_ifaces">
													<th>组播流向</th>
													<td>
														<span style="margin-left:4px" id="igmpproxy_ifaces">查询中...</span>
													</td>
												</tr>
												<tr id="ig_daemon">
													<th id="th_daemon">进程守护</th>
													<td>
														<span style="margin-left:4px" id="igmpproxy_daemon">查询中...</span>
													</td>
												</tr>
												<tr id="ig_router">
													<th>固件环境</th>
													<td>
														<span style="margin-left:4px" id="igmpproxy_router_state"></span>
													</td>
												</tr>
												<tr id="ig_mr_warn" style="display: none;">
													<th></th>
													<td>
														<span style="margin-left:4px;color:#FC0">路由器自身的「启动组播路由」开着，会和本插件抢 IGMP，必须先关掉它。</span>
														<div style="margin-top:8px">
															<!-- 内联样式锁死尺寸：button_gen 固定 width:122px + white-space:normal，长文案会被挤成多行，
														     鼠标悬停换背景色时看起来像“变形” -->
														<input type="button" class="button_gen" style="width:auto;height:33px;padding:0 12px;white-space:nowrap" value="一键关闭路由器自身组播路由" onClick="do_cmd('mr_off')">
														</div>
													</td>
												</tr>
											</table>
										</div>
										<div id="igmpproxy_settings" style="margin-top:10px">
											<table width="100%" border="1" align="center" cellpadding="4" cellspacing="0" bordercolor="#6b8fa3" class="FormTable">
												<thead>
													<tr>
														<td colspan="2">IGMP Proxy - 设置（点击标签文字查看该项说明）</td>
													</tr>
												</thead>
												<tr>
													<th>上游接口</th>
													<td>
														<select id="igmpproxy_upstream" class="input_option" style="margin-left:4px"></select>
														<input type="text" id="igmpproxy_upstream_custom" class="input_3_table" style="margin-left:4px;display:none;width:80px" placeholder="例：vlan3">
													</td>
												</tr>
												<tr>
													<th>下游接口</th>
													<td>
														<select id="igmpproxy_downstream" class="input_option" style="margin-left:4px"></select>
														<input type="text" id="igmpproxy_downstream_custom" class="input_3_table" style="margin-left:4px;display:none;width:80px" placeholder="例：br1">
													</td>
												</tr>
												<tr>
													<th>组播源网段</th>
													<td>
														<input type="text" id="igmpproxy_altnet" class="input_32_table" style="margin-left:4px" placeholder="例：10.0.0.0/8 192.168.0.0/16">
													</td>
												</tr>
												<tr>
													<th>快速换台</th>
													<td>
														<input type="checkbox" id="igmpproxy_quickleave" style="vertical-align:middle;">
													</td>
												</tr>
												<tr>
													<th>添加防火墙组播规则</th>
													<td>
														<input type="checkbox" id="igmpproxy_firewall" style="vertical-align:middle;">
													</td>
												</tr>
												<tr>
													<th>关闭反向路径过滤</th>
													<td>
														<input type="checkbox" id="igmpproxy_rpfilter" style="vertical-align:middle;">
													</td>
												</tr>
												<tr>
													<th>实时进程守护</th>
													<td>
														<input type="checkbox" id="igmpproxy_watchdog" style="vertical-align:middle;">
													</td>
												</tr>
												<tr>
													<th>强制接管</th>
													<td>
														<input type="checkbox" id="igmpproxy_force" style="vertical-align:middle;">
													</td>
												</tr>
											</table>
										</div>
										<div style="margin:10px 0 10px 0; text-align:center;">
											<input type="hidden" id="igmpproxy_enable" value="">
											<input class="button_gen" id="igmpproxy_apply_1" type="button" style="margin-left:5px;" onClick="save(1)" value="开启">
											<input class="button_gen" id="igmpproxy_apply_2" type="button" style="margin-left:5px;" onClick="save(2)" value="重启">
											<input class="button_gen" id="igmpproxy_apply_0" type="button" style="margin-left:5px;" onClick="save(0)" value="关闭">
										</div>
									</td>
								</tr>
							</table>
						</td>
					</tr>
				</table>
			</td>
		</tr>
	</table>
	<div id="footer"></div>
</body>
</html>

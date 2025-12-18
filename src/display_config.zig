/// Display configuration constants for e-ink display layout
/// Display: 296x128 pixels (landscape)
/// Layout matches original Python version

// Display dimensions
pub const DISPLAY_WIDTH = 296;
pub const DISPLAY_HEIGHT = 128;

// Grid layout - vertical dividers
pub const VERTICAL_LINE_1 = 100;
pub const VERTICAL_LINE_2 = 201;

// Grid layout - horizontal dividers
pub const HORIZONTAL_LINE_MAIN = 110;

// Section boundaries
pub const SECTION_CPU_LEFT = 0;
pub const SECTION_CPU_RIGHT = 100;
pub const SECTION_NVME_LEFT = 100;
pub const SECTION_NVME_RIGHT = 201;
pub const SECTION_TRAFFIC_LEFT = 201;
pub const SECTION_TRAFFIC_RIGHT = 296;

// CPU section coordinates
pub const CPU_LABEL_Y = 6;
pub const CPU_LINE_Y = 10;
pub const CPU_ICON_X = 13;
pub const CPU_ICON_Y_LOAD = 18;
pub const CPU_ICON_Y_TEMP = 48;
pub const CPU_VALUE_X = 43;
pub const CPU_VALUE_Y_LOAD = 18;
pub const CPU_VALUE_Y_TEMP = 48;

// Memory section coordinates
pub const MEM_LABEL_X = 1;
pub const MEM_LABEL_Y = 75;
pub const MEM_LINE_Y = 76;
pub const MEM_ICON_X = 10;
pub const MEM_ICON_Y = 86;
pub const MEM_VALUE_X = 40;
pub const MEM_VALUE_Y = 87;

// NVMe section coordinates
pub const NVME_LABEL_X = 102;
pub const NVME_LABEL_Y = 7;
pub const NVME_LINE_Y = 10;
pub const NVME_ICON_X = 108;
pub const NVME_ICON_Y_DISK = 18;
pub const NVME_ICON_Y_TEMP = 48;
pub const NVME_VALUE_X = 138;
pub const NVME_VALUE_Y_DISK = 19;
pub const NVME_VALUE_Y_TEMP = 49;

// Fan section coordinates
pub const FAN_LABEL_X = 102;
pub const FAN_LABEL_Y = 73;
pub const FAN_LINE_Y = 76;
pub const FAN_ICON_X = 108;
pub const FAN_ICON_Y = 86;
pub const FAN_VALUE_X = 138;
pub const FAN_VALUE_Y = 86;

// Updates section coordinates
pub const APT_LABEL_X = 203;
pub const APT_LABEL_Y = 75;
pub const APT_LINE_Y = 76;
pub const APT_VALUE_X = 214;
pub const APT_VALUE_Y = 89;

// Network status section coordinates
pub const NET_LABEL_X = 250;
pub const NET_LABEL_Y = 75;
pub const NET_LINE_X = 249;
pub const NET_LINE_Y = 76;
pub const NET_ICON_X = 260;
pub const NET_ICON_Y = 89;

// Traffic section coordinates
pub const TRAFFIC_DOWN_LABEL_X = 203;
pub const TRAFFIC_DOWN_LABEL_Y = 6;
pub const TRAFFIC_DOWN_LINE_Y = 10;
pub const TRAFFIC_DOWN_ICON_X = 208;
pub const TRAFFIC_DOWN_ICON_Y = 16;
pub const TRAFFIC_DOWN_VALUE_X = 233;
pub const TRAFFIC_DOWN_VALUE_Y = 19;
pub const TRAFFIC_DOWN_UNIT_X = 263;
pub const TRAFFIC_DOWN_UNIT_Y = 6;

pub const TRAFFIC_UP_LABEL_X = 203;
pub const TRAFFIC_UP_LABEL_Y = 39;
pub const TRAFFIC_UP_LINE_Y = 43;
pub const TRAFFIC_UP_ICON_X = 208;
pub const TRAFFIC_UP_ICON_Y = 50;
pub const TRAFFIC_UP_VALUE_X = 233;
pub const TRAFFIC_UP_VALUE_Y = 53;
pub const TRAFFIC_UP_UNIT_X = 263;
pub const TRAFFIC_UP_UNIT_Y = 39;

// Bottom bar coordinates
pub const IP_ICON_X = 5;
pub const IP_ICON_Y = 116;
pub const IP_VALUE_X = 20;
pub const IP_VALUE_Y = 119;

pub const SIGNAL_ICON_X = 125;
pub const SIGNAL_ICON_Y = 116;
pub const SIGNAL_VALUE_X = 140;
pub const SIGNAL_VALUE_Y = 119;

pub const UPTIME_ICON_X = 205;
pub const UPTIME_ICON_Y = 116;
pub const UPTIME_VALUE_X = 220;
pub const UPTIME_VALUE_Y = 119;

// Text area sizes for clearing (width x height)
pub const TEXT_AREA_CPU = .{ .width = 60, .height = 24 };
pub const TEXT_AREA_MEM = .{ .width = 60, .height = 26 };
pub const TEXT_AREA_NVME = .{ .width = 60, .height = 26 };
pub const TEXT_AREA_FAN = .{ .width = 60, .height = 24 };
pub const TEXT_AREA_IP = .{ .width = 100, .height = 14 };
pub const TEXT_AREA_UPTIME = .{ .width = 70, .height = 14 };
pub const TEXT_AREA_SIGNAL = .{ .width = 80, .height = 14 };
pub const TEXT_AREA_TRAFFIC_VALUE = .{ .width = 50, .height = 20 };
pub const TEXT_AREA_TRAFFIC_UNIT = .{ .width = 30, .height = 14 };
pub const TEXT_AREA_APT = .{ .width = 40, .height = 24 };
pub const TEXT_AREA_NET = .{ .width = 40, .height = 24 };

// Unicode icons (UTF-8 encoded)
// Note: These require proper font support
pub const ICON_CPU = "\u{e30d}";
pub const ICON_TEMPERATURE = "\u{e1ff}";
pub const ICON_MEMORY = "\u{e322}";
pub const ICON_HARD_DRIVE = "\u{f7a4}";
pub const ICON_FAN = "\u{f168}";
pub const ICON_NETWORK = "\u{e80d}";
pub const ICON_UPTIME = "\u{e923}";
pub const ICON_DOWNLOAD = "\u{f090}";
pub const ICON_UPLOAD = "\u{f09b}";
pub const ICON_CHECK = "\u{e8e8}";
pub const ICON_WIFI_OK = "\u{e2bf}";
pub const ICON_WIFI_OFF = "\u{f1ca}";
pub const ICON_WIFI_SIGNAL = "\u{e63e}";
pub const ICON_WIFI_NO_SIGNAL = "\u{e1da}";

// Sleep screen coordinates
pub const SLEEP_LINE_X = 136;
pub const SLEEP_LINE_Y = 15;
pub const SLEEP_LINE_W = 3;
pub const SLEEP_ICON_X = 65;
pub const SLEEP_ICON_Y = 47;
pub const SLEEP_TEXT_TITLE_X = 155;
pub const SLEEP_TEXT_TITLE_Y = 44;
pub const SLEEP_TEXT_SUB_X = 160;
pub const SLEEP_TEXT_SUB_Y = 77;

pub const ICON_SLEEP_NET = "\u{eb2f}";

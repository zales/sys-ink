/// Display configuration constants for e-ink display layout
/// Display: 296x128 pixels (landscape)
/// Layout matches original Python version

// Display dimensions
pub const DISPLAY_WIDTH = 296;
pub const DISPLAY_HEIGHT = 128;
pub const DEBUG_TEXT_AREAS = false; // draw debug frames around text clear areas

// Grid layout - vertical dividers
pub const VERTICAL_LINE_1 = 100;
pub const VERTICAL_LINE_2 = 201;

// Grid layout - horizontal dividers
pub const HORIZONTAL_LINE_MAIN = 110;

// Section boundaries (used in renderGrid)
pub const SECTION_CPU_RIGHT = 100;
pub const SECTION_DISK_RIGHT = 201;

// CPU section coordinates
pub const CPU_LABEL_Y = 11;
pub const CPU_LINE_Y = 7;
pub const CPU_ICON_X = 3;
pub const CPU_ICON_Y_LOAD = 37;
pub const CPU_ICON_Y_TEMP = 66;
pub const CPU_VALUE_X = 34;
pub const CPU_VALUE_Y_LOAD = 35;
pub const CPU_VALUE_Y_TEMP = 63;
pub const CPU_AREA_X = 32;
pub const CPU_AREA_Y_LOAD = 13;
pub const CPU_AREA_Y_TEMP = 41;

// Memory section coordinates
pub const MEM_LABEL_X = 1;
pub const MEM_LABEL_Y = 80;
pub const MEM_LINE_Y = 76;
pub const MEM_ICON_X = 3;
pub const MEM_ICON_Y = 105;
pub const MEM_VALUE_X = 34;
pub const MEM_VALUE_Y = 102;
pub const MEM_AREA_X = 32;
pub const MEM_AREA_Y = 81; // baseline(102) - ascent(21) = 81

// Disk section coordinates
pub const DISK_LABEL_X = 102;
pub const DISK_LABEL_Y = 11;
pub const DISK_LINE_Y = 7;
pub const DISK_ICON_X = 103;
pub const DISK_ICON_Y_DISK = 37;
pub const DISK_ICON_Y_TEMP = 66;
pub const DISK_VALUE_X = 132;
pub const DISK_VALUE_Y_DISK = 35;
pub const DISK_VALUE_Y_TEMP = 64;
pub const DISK_AREA_X = 130;
pub const DISK_AREA_Y_DISK = 13;
pub const DISK_AREA_Y_TEMP = 42;

// Fan section coordinates
pub const FAN_LABEL_X = 102;
pub const FAN_LABEL_Y = 80;
pub const FAN_LINE_Y = 76;
pub const FAN_ICON_X = 103;
pub const FAN_ICON_Y = 105;
pub const FAN_VALUE_X = 133;
pub const FAN_VALUE_Y = 102;

// Updates section coordinates
pub const APT_LABEL_X = 203;
pub const APT_LABEL_Y = 80;
pub const APT_LINE_Y = 76;
pub const APT_VALUE_X = 214;
pub const APT_VALUE_Y = 105;

// Network status section coordinates
pub const NET_LABEL_X = 250;
pub const NET_LABEL_Y = 80;
pub const NET_LINE_X = 249;
pub const NET_LINE_Y = 76;
pub const NET_ICON_X = 260;
pub const NET_ICON_Y = 105;

// Traffic section coordinates
pub const TRAFFIC_DOWN_LABEL_X = 203;
pub const TRAFFIC_DOWN_LABEL_Y = 11;
pub const TRAFFIC_DOWN_LINE_Y = 7;
pub const TRAFFIC_DOWN_ICON_X = 208;
pub const TRAFFIC_DOWN_ICON_Y = 35;
pub const TRAFFIC_DOWN_VALUE_X = 233;
pub const TRAFFIC_DOWN_VALUE_Y = 30;
pub const TRAFFIC_DOWN_AREA_Y = 12; // VALUE_Y(30) - ascent(18) = 12
pub const TRAFFIC_DOWN_UNIT_X = 263;
pub const TRAFFIC_DOWN_UNIT_Y = 11;
pub const TRAFFIC_DOWN_UNIT_AREA_Y = 0; // UNIT_Y(11) - ascent(11) = 0

pub const TRAFFIC_UP_LABEL_X = 203;
pub const TRAFFIC_UP_LABEL_Y = 45;
pub const TRAFFIC_UP_LINE_Y = 41;
pub const TRAFFIC_UP_ICON_X = 208;
pub const TRAFFIC_UP_ICON_Y = 70;
pub const TRAFFIC_UP_VALUE_X = 233;
pub const TRAFFIC_UP_VALUE_Y = 65;
pub const TRAFFIC_UP_AREA_Y = 47; // VALUE_Y(65) - ascent(18) = 47
pub const TRAFFIC_UP_UNIT_X = 263;
pub const TRAFFIC_UP_UNIT_Y = 45;
pub const TRAFFIC_UP_UNIT_AREA_Y = 34; // UNIT_Y(45) - ascent(11) = 34

// Bottom bar coordinates
pub const IP_ICON_X = 0;
pub const IP_ICON_Y = 127;
pub const IP_VALUE_X = 15;
pub const IP_VALUE_Y = 125;
pub const IP_AREA_Y = 113; // VALUE_Y(125) - ascent(11) - 1 = 113

pub const SIGNAL_ICON_X = 125;
pub const SIGNAL_ICON_Y = 127;
pub const SIGNAL_VALUE_X = 140;
pub const SIGNAL_VALUE_Y = 125;
pub const SIGNAL_AREA_Y = 113; // VALUE_Y(125) - ascent(11) - 1 = 113

pub const UPTIME_ICON_X = 205;
pub const UPTIME_ICON_Y = 127;
pub const UPTIME_VALUE_X = 220;
pub const UPTIME_VALUE_Y = 125;
pub const UPTIME_AREA_Y = 113; // VALUE_Y(125) - ascent(11) - 1 = 113

// Text area sizes for clearing (width x height)
pub const TEXT_AREA_CPU = .{ .width = 66, .height = 27 };
pub const TEXT_AREA_MEM = .{ .width = 65, .height = 25 };
pub const TEXT_AREA_DISK = .{ .width = 70, .height = 27 };
pub const TEXT_AREA_FAN = .{ .width = 60, .height = 27 };
pub const TEXT_AREA_IP = .{ .width = 105, .height = 14 };
pub const TEXT_AREA_UPTIME = .{ .width = 76, .height = 14 };
pub const TEXT_AREA_SIGNAL = .{ .width = 80, .height = 14 };
pub const TEXT_AREA_TRAFFIC_VALUE = .{ .width = 75, .height = 20 };
pub const TEXT_AREA_TRAFFIC_UNIT = .{ .width = 35, .height = 14 };
pub const TEXT_AREA_APT = .{ .width = 35, .height = 24 };
pub const TEXT_AREA_NET = .{ .width = 35, .height = 24 };

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

// Sleep/Loading screen constants
pub const SLEEP_LINE_X = 124;
pub const SLEEP_LINE_Y = 15;
pub const SLEEP_LINE_W = 3;
pub const SLEEP_LINE_H = 95;
pub const SLEEP_ICON_X = 50;
pub const SLEEP_ICON_Y = 82;
pub const SLEEP_TITLE_X = 155;
pub const SLEEP_TITLE_Y = 60;
pub const SLEEP_SUBTITLE_X = 155;
pub const SLEEP_SUBTITLE_Y = 82;
pub const ICON_SLEEP_NET = "\u{eb2f}";

implement Stvga;

include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";

Stvga: module
{
	init: fn(nil: ref Draw->Context, nil: list of string);
};

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;

	sys->bind("#v", "/dev", Sys->MAFTER);
	fd := sys->open("/dev/vgactl", Sys->ORDWR);
	if(fd == nil){
		sys->print("open failed: %r\n");
		exit;
	}
	msg := array of byte "type basevga";
	if(sys->write(fd, msg, len msg) < 0)
		sys->print("type write failed: %r\n");
	fd = sys->open("/dev/vgactl", Sys->ORDWR);
#	msg2 := array of byte "size 320x200x8 m8";
	msg2 := array of byte "size 640x480x4 m4";
	if(sys->write(fd, msg2, len msg2) < 0)
		sys->print("size write failed: %r\n");
	fd = sys->open("/dev/vgactl", Sys->ORDWR);
	msg3 := array of byte "drawinit";
	if(sys->write(fd, msg3, len msg3) < 0)
		sys->print("drawinit write failed: %r\n");
	fd = sys->open("/dev/vgactl", Sys->ORDWR);
	msg4 := array of byte "hwaccel off";
	if(sys->write(fd, msg4, len msg4) < 0)
		sys->print("hwaccel write failed: %r\n");
	fd = sys->open("/dev/vgactl", Sys->ORDWR);
	msg5 := array of byte "hwgc basevgagc";
	if(sys->write(fd, msg5, len msg5) < 0)
		sys->print("hwgc write failed: %r\n");
	if(sys->bind("#i", "/dev", Sys->MAFTER) < 0)
		sys->print("bind devdraw: %r\n");

	wm := load Command "/dis/wm/wm.dis" ;
	wm->init(nil, "wm/wm" :: nil);

	
}

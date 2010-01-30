implement Lapfs;

include "sys.m";
	sys: Sys;
include "draw.m";
include "string.m";
	str: String;
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;
include "arg.m";
	arg: Arg;
include "hash.m";
	hash: Hash;
	HashTable, HashVal: import hash;

Lapfs: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

Port: con 1962;

msize, dflag: int;
fidqidtab: ref HashTable;

init(nil: ref Draw->Context, args: list of string)
{
	r: ref Rmsg;

	sys = load Sys Sys->PATH;
	str = load String String->PATH;
	styx = load Styx Styx->PATH;
	arg = load Arg Arg->PATH;
	hash = load Hash Hash->PATH;

	styx->init();

	arg->init(args);
	dflag = 0;
	arg->setusage("Usage: lapfs [-d] cache [server]\n");
	while((c := arg->opt()) != 0){
		case c {
		'd' =>
			dflag = 1;
		* =>
			arg->usage();
			exit;
		}
	}

	args = arg->argv();

	if(len args < 1 || len args > 2){
		arg->usage();
		exit;
	}

	cacheonly := 0;
	if(len args == 1)
		cacheonly = 1;

	spawn daemon(args, cacheonly);
}

daemon(args: list of string, cacheonly: int)
{
	tfs: chan of array of byte;
	rfs: chan of (array of byte, ref Rmsg);
	ctlfs: chan of (int, int);
	fsrpid, fswpid: int;
	wbfd: ref Sys->FD;

	if(len args == 2){
		if(dflag)
			sys->fprint(sys->fildes(2), "opening server: %s\n", hd tl args);
		tfs = chan of array of byte;
		rfs = chan of (array of byte, ref Rmsg);
		ctlfs = chan of (int, int);
		server := hd tl args;

		spawn client(server, tfs, rfs, ctlfs);
		(fsrpid, fswpid) = <- ctlfs;
		if(fsrpid < 0)
			exit;
		if(fsrpid == 0)
			cacheonly = 1;
		else{
			wbfd = sys->open("wblog", Sys->OREAD);
			if(wbfd != nil){
				playback(tfs, rfs, wbfd);
				wbfd = sys->create("wblog", Sys->OWRITE, 8r600);
				kill(fsrpid);
				kill(fswpid);
				spawn client(server, tfs, rfs, ctlfs);
				(fsrpid, fswpid) = <- ctlfs;
			}
		}
	}
	else{
		wbfd = sys->open("wblog", Sys->OWRITE);
		if(wbfd == nil)
			sys->print("Could not open write-back log: %r\n");
	}

	if(dflag)
		sys->fprint(sys->fildes(2), "opening cache: %s\n", hd args);
	tcache := chan of array of byte;
	rcache := chan of (array of byte, ref Rmsg);
	ctlcache := chan of (int, int);
	cachefs := hd args;

	spawn client(cachefs, tcache, rcache, ctlcache);
	(cacherpid, cachewpid) := <- ctlcache;
	if(cacherpid < 0)
		exit;

	if(dflag)
		sys->fprint(sys->fildes(2), "starting client proc\n");
	tclient := chan of (array of byte, ref Tmsg);
	rclient := chan of array of byte;
	ctlclient := chan of (int, int);

	spawn servproc(tclient, rclient, ctlclient);
	(clientrpid, clientwpid) := <- ctlclient;
	if(clientrpid < 0)
		exit;

	if(dflag)
		sys->print("cacher:%d cachew:%d clientr:%d clientw:%d fsr:%d fsw:%d\n",
			cacherpid, cachewpid, clientrpid, clientwpid, fsrpid, fswpid);

	fidqidtab = hash->new(31);

	while(1){
		(m, t) := <- tclient;
		if(t != nil){
			if(!cacheonly)
				procclient(m, t, rclient, tfs, rfs, tcache, rcache);
			else
				procclientco(m, t, rclient, tcache, rcache, wbfd);
		}
		else{
			sys->print("Got nil message from client\n");
			break;
		}
	}
	kill(cacherpid);
	kill(cachewpid);
	kill(clientrpid);
	kill(clientwpid);
	if(!cacheonly){
		kill(fsrpid);
		kill(fswpid);
	}
}

procclient(m: array of byte, t: ref Tmsg, rcli: chan of array of byte,
	fch: chan of array of byte, rfch: chan of (array of byte, ref Rmsg),
	cch: chan of array of byte, rcch: chan of (array of byte, ref Rmsg))
{
	r: ref Rmsg;
	mr: array of byte;

	if(dflag)
		showmsg(t);
	pick x := t {
	Readerror =>
		sys->print("Got Readerror from client: %s\n", x.error);
	Version =>
		fch <-= m;
		cch <-= m;
		(mr, r) = <- rfch;
		rcli <-= mr;
		<- rcch;
	Auth =>
	Attach =>
		fch <-= m;
		cch <-= m;
		(mr, r) = <- rfch;
		rcli <-= mr;
		pick rr := r {
		Attach =>
			qidstr := sys->sprint("%bd %d %d %d",
				rr.qid.path, rr.qid.vers, rr.qid.qtype, 8r777);
			fidqidtab.insert(string x.fid, HashVal(0, 0.0, qidstr));
		}
		<- rcch;
	Flush =>
		fch <-= m;
		cch <-= m;
		(mr, r) = <- rfch;
		rcli <-= mr;
		<- rcch;
	Walk =>
		fch <-= m;
		cch <-= m;
		(nil, cr) := <- rcch;
		(mr, r) = <- rfch;
		pick fr := r {
		Walk =>
			pick ccr := cr {
			Walk =>
				if(dflag)
					sys->print("fr: %d ccr:%d\n", len fr.qids, len ccr.qids);
				lf := len fr.qids;
				if(lf == len ccr.qids)
					rcli <- = mr;
				else{
					n := len ccr.qids;
					buildpath(x, fr, n, cch, rcch);
					rcli <-= mr;
				}
				if(lf == 0){
					qh := fidqidtab.find(string x.fid);
					if(qh == nil){
						sys->print("fid %d missing from hash table in walk\n",
							x.fid);
					}
					else{
						fidqidtab.insert(string x.newfid, HashVal(0, 0.0, qh.s));
					}
				}
				else if(lf == len x.names){
					q := fr.qids[lf - 1];
					qidstr := sys->sprint("%bd %d %d %d",
						q.path, q.vers, q.qtype, 8r777);
					fidqidtab.insert(string x.newfid, HashVal(0, 0.0, qidstr));
				}
			Error =>
				buildpath(x, fr, 0, cch, rcch);
				rcli <-= mr;
			}
		Error =>
			rcli <- = mr;
		}
	Open =>
		fch <-= m;
		stmsg := ref Tmsg.Stat(16rfff5, x.fid);
		cch <-= stmsg.pack();
		(nil, stresp) := <- rcch;
		mode := 8r777;
		pick s := stresp {
		Stat =>
			mode = s.stat.mode;
			if((s.stat.qid.qtype & Sys->QTDIR) == 0){
				if((s.stat.mode & 8r200) == 0){
					nstat := Sys->nulldir;
					nstat.mode = s.stat.mode | 8r200;
					twstat := ref Tmsg.Wstat(16rfffd, x.fid, nstat);
					cch <-= twstat.pack();
					<- rcch;
				}
				x.mode = Sys->ORDWR;
			}
		* =>
			sys->fprint(sys->fildes(2), "Unexpected error in open: %r\n");
		}
		cch <-= x.pack();
		(mr, r) = <- rfch;
		rcli <-= mr;
		(nil, rc) := <- rcch;
		pick prc := rc {
		Error =>
			sys->print("Error in open: %s\n", prc.ename);
		}
		pick rr := r {
		Open =>
			qidstr := sys->sprint("%bd %d %d %d",
				rr.qid.path, rr.qid.vers, rr.qid.qtype, mode);
			fidqidtab.insert(string x.fid, HashVal(0, 0.0, qidstr));
		}
	Create =>
		fch <-= m;
		mode := x.perm;
		if((mode & Sys->DMDIR) == 0)
			x.perm |= 8r200;
		cch <-= x.pack();
		(mr, r) = <- rfch;
		rcli <-= mr;
		pick rr := r {
		Create =>
			qidstr := sys->sprint("%bd %d %d %d",
				rr.qid.path, rr.qid.vers, rr.qid.qtype, mode);
			fidqidtab.insert(string x.fid, HashVal(0, 0.0, qidstr));
		}
		<- rcch;
	Read =>
		fch <-= m;
		(mr, r) = <- rfch;
		rcli <-= mr;
		pick pr := r {
		Read =>
			qt := Sys->QTDIR;
			fq := fidqidtab.find(string x.fid);
			if(fq != nil){
				(n, l) := sys->tokenize(fq.s, " ");
				if(n == 4)
					qt = int hd tl tl l;
				else
					sys->print("Malformed hash entry: %d\n", n);
			}
			else
				sys->print("Unexpected missing FID in hash table: %d\n",
					x.fid);
			if((qt & Sys->QTDIR) == 0){
				twrite := ref Tmsg.Write(16rfffe, x.fid, x.offset, pr.data);
				if(twrite != nil){
					cch <-= twrite.pack();
					(nil, rc) := <- rcch;
					pick prc := rc {
					Error =>
						sys->print("Write from read to cache failed: %s\n",
							prc.ename);
					}
				}
				else{
					sys->print("Failed to create write message in read\n");
				}
			}
		* =>
			sys->print("Bad read response\n");
		}
	Write =>
		fch <-= m;
		cch <-= m;
		(mr, r) = <- rfch;
		rcli <-= mr;
		<- rcch;
	Clunk =>
		fch <-= m;
		(mr, r) = <- rfch;
		rcli <-= mr;
		fq := fidqidtab.find(string x.fid);
		if(fq != nil){
			(n, l) := sys->tokenize(fq.s, " ");
			if(n != 4)
				sys->print("malformed fidqid entry: %s\n", fq.s);
			else{
				mode := int hd tl tl tl l;
				if((mode & 8r200) == 0){
					ws := Sys->nulldir;
					ws.mode = mode;
					twstat := ref Tmsg.Wstat(16rfffd, x.fid, ws);
					cch <-= twstat.pack();
					<- rcch;
				}
			}
		}
		else
			sys->print("Missing fid in fid-qid table: %d\n", x.fid);
		cch <-= m;
		fidqidtab.delete(string x.fid);
		if(dflag)
			sys->print("clunked: %d, fidqidtab size: %d\n", x.fid, len fidqidtab.all());
		<- rcch;
	Remove =>
		fch <-= m;
		cch <-= m;
		(mr, r) = <- rfch;
		rcli <-= mr;
		fidqidtab.delete(string x.fid);
		<- rcch;
	Stat =>
		fch <-= m;
		(mr, r) = <- rfch;
		rcli <-= mr;
		pick pr := r {
		Stat =>
			if(dflag)
				sys->print("mode:%uo len:%bd", pr.stat.mode, pr.stat.length);
			ws := Sys->nulldir;
			ws.mode = pr.stat.mode;
			ws.atime = pr.stat.atime;
			ws.mtime = pr.stat.mtime;
			ws.length = pr.stat.length;
			twstat := ref Tmsg.Wstat(16rfffd, x.fid, ws);
			cch <-= twstat.pack();
			<- rcch;
		* =>
			sys->print("Bad stat response\n");
		}
		if(dflag)
			sys->print("\n");
	Wstat =>
		fch <-= m;
		cch <-= m;
		(mr, r) = <- rfch;
		rcli <-= mr;
		<- rcch;
	* =>
		sys->print("Got unknown client message:\n");
		fch <-= m;
		cch <-= m;
		(mr, r) = <- rfch;
		rcli <-= mr;
		<- rcch;
	}
}

buildpath(x: ref Tmsg.Walk, fr: ref Rmsg.Walk, n: int,
	cch: chan of array of byte, rcch: chan of (array of byte, ref Rmsg))
{
	if(dflag)
		sys->fprint(sys->fildes(2), "In buildpath, n=%d\n", n);
	for(i := n; i < len fr.qids - 1; ++i){
		twalk := ref Tmsg.Walk(16rfffc, x.fid, 9999, x.names[:i]);
		cch <-= twalk.pack();
		(nil, tw) := <- rcch;
		if(dflag)
			sys->fprint(sys->fildes(2), "Creating %s in buildpath\n", x.names[i]);
		tcreate := ref Tmsg.Create(16rfffb, 9999, x.names[i],
			8r755 | Styx->DMDIR, Sys->OREAD);
		cch <- = tcreate.pack();
		(nil, rcreate) := <- rcch;
		pick rc2 := rcreate {
		Error =>
			sys->print("Create failed in walk: %s\n", rc2.ename);
			return;
		}
		tclunk := ref Tmsg.Clunk(16rfffa, 9999);
		cch <-= tclunk.pack();
		<- rcch;
	}
	twalk := ref Tmsg.Walk(16rfff9, x.fid, 9999, x.names[:len fr.qids - 1]);
	cch <-= twalk.pack();
	(nil, tw) := <- rcch;
	if(fr.qids[len fr.qids-1].qtype & Styx->QTDIR)
		perm := 8r755 | Styx->DMDIR;
	else
		perm = 8r755;
	tcreate := ref Tmsg.Create(16rfff8, 9999,
		x.names[len fr.qids-1], perm, Sys->OREAD);
	cch <-= tcreate.pack();
	<- rcch;
	tclunk := ref Tmsg.Clunk(16rfff7, 9999);
	cch <-= tclunk.pack();
	<- rcch;
	twalk = ref Tmsg.Walk(16rfff6, x.fid, x.newfid, x.names);
	cch <-= twalk.pack();
	(nil, tw) = <- rcch;
}

procclientco(m: array of byte, t: ref Tmsg, rcli: chan of array of byte, 
	cch: chan of array of byte, rcch: chan of (array of byte, ref Rmsg),
	wbfd: ref Sys->FD)
{
	r: ref Rmsg;
	b: array of byte;

	if(dflag)
		showmsg(t);
	pick x := t {
	Readerror =>
		sys->print("Got Readerror from client: %s\n", x.error);
	Version =>
		cch <-= m;
		(b, r) = <- rcch;
		rcli <-= b;
	Attach =>
		cch <-= m;
		(b, r) = <- rcch;
		rcli <-= b;
		if(wbfd != nil){
			sys->write(wbfd, m, len m);
		}
	Flush =>
		cch <-= m;
		(b, r) = <- rcch;
		rcli <-= b;
		if(wbfd != nil){
			sys->write(wbfd, m, len m);
		}
	Walk =>
		cch <-= m;
		(b, r) = <- rcch;
		rcli <-= b;
		if(wbfd != nil){
			sys->write(wbfd, m, len m);
		}
	Create =>
		cch <-= m;
		(b, r) = <- rcch;
		rcli <-= b;
		if(wbfd != nil){
			sys->write(wbfd, m, len m);
		}
	Write =>
		cch <-= m;
		(b, r) = <- rcch;
		rcli <-= b;
		if(wbfd != nil){
			sys->write(wbfd, m, len m);
		}
	Wstat =>
		cch <-= m;
		(b, r) = <- rcch;
		rcli <-= b;
		if(wbfd != nil){
			sys->write(wbfd, m, len m);
		}
	Open =>
		cch <-= m;
		(b, r) = <- rcch;
		rcli <-= b;
		if(wbfd != nil){
			sys->write(wbfd, m, len m);
		}
	Read =>
		cch <-= m;
		(b, r) = <- rcch;
		rcli <-= b;
	Stat =>
		cch <-= m;
		(b, r) = <- rcch;
		rcli <-= b;
	Clunk =>
		cch <-= m;
		(b, r) = <- rcch;
		rcli <-= b;
		if(wbfd != nil){
			sys->write(wbfd, m, len m);
		}
	Remove =>
		cch <-= m;
		(b, r) = <- rcch;
		rcli <-= b;
		if(wbfd != nil){
			sys->write(wbfd, m, len m);
		}
	* =>
		sys->print("Got unknown client message\n");
		cch <-= m;
		(b, r) = <- rcch;
		rcli <-= b;
	}
}

playback(fch: chan of array of byte, frch: chan of (array of byte, ref Rmsg),
	fd: ref Sys->FD)
{
	while(1){
		t := Tmsg.read(fd, 0);
		if(t == nil)
			break;
		fch <-= t.pack();
		if(dflag)
			showmsg(t);
		(nil, r) := <- frch;
		pick pr := r {
		Error =>
			sys->print("Unexpected error in replay: %r\n");
		}
	}
		
}

servproc(tchan: chan of (array of byte, ref Tmsg),
	rchan: chan of array of byte, ctl: chan of (int, int))
{
	(r1, c1) := sys->announce("tcp!*!" + string Port);
	if(r1 < 0){
		sys->print("failed to announce server process: %r\n");
		ctl <-= (-1, 0);
		exit;
	}
	(r2, c2) := sys->listen(c1);
	if(r2 < 0){
		sys->print("listen failed in server process: %r\n");
		ctl <-= (-1, 0);
		exit;
	}
	fd := sys->open(c2.dir + "/data", Sys->ORDWR);
	if(fd == nil){
		sys->print("failed to open data port in server process: %r\n");
		ctl <-= (-1, 0);
		exit;
	}
	rctl := chan of int;
	wctl := chan of int;
	spawn sreader(tchan, rctl, fd);
	spawn swriter(rchan, wctl, fd);
	rpid := <- rctl;
	wpid := <- wctl;
	ctl <-= (rpid, wpid);
}

client(addr: string, tchan: chan of array of byte,
	rchan: chan of (array of byte, ref Rmsg), ctl: chan of (int, int))
{
	fd: ref Sys->FD;

	if(str->prefix("/chan", addr)){
		fd = sys->open(addr, Sys->ORDWR);
		if(fd == nil){
			sys->print("client failed to open %s: %r\n", addr);
			ctl <-= (-1, 0);
			return;
		}
	}
	else if(str->drop(addr, "^!") != nil){
		(r, c) := sys->dial(addr, "");
		if(r < 0){
			sys->print("client could not dial %s: %r\n", addr);
			ctl <-= (0,0);
		}
		else
			fd = c.dfd;
	}
	else if(addr[0] == '#' || addr[0] == '/'){
		pfd := array[2] of ref Sys->FD;
		if(sys->pipe(pfd) < 0){
			sys->print("client could not create pipe: %r\n");
			ctl <-= (-1, 0);
			return;
		}
		fd = pfd[0];
		if(sys->export(pfd[1], addr, Sys->EXPASYNC) < 0){
			sys->print("client could not export: %s: %r\n", addr);
			ctl <-= (-1, 0);
			return;
		}
	}
	else{
		sys->print("ambiguous address in client: %s: %r\n", addr);
		ctl <-= (-1, 0);
		return;
	}
	rctl := chan of int;
	wctl := chan of int;
	spawn creader(rchan, rctl, fd);
	spawn cwriter(tchan, wctl, fd);
	rpid := <- rctl;
	wpid := <- wctl;
	ctl <-= (rpid, wpid);
}

sreader(tchan: chan of (array of byte, ref Tmsg), ctl: chan of int, fd: ref Sys->FD)
{
	t: ref Tmsg;

	pid := sys->pctl(0, nil);
	ctl <-= pid;

	while(1){
		(m, e) := styx->readmsg(fd, msize);
		if(e != nil){
			sys->print("readmsg failure in sreader: %s\n", e);
			continue;
		}
		if(m != nil){
			(nil, t) = Tmsg.unpack(m);
			if(t != nil)
				tchan <-= (m, t);
		}
		else
			tchan <-= (nil, nil);
#		t = Tmsg.read(fd, msize);
#		tchan <-= t;
#		t = nil;
	}
}

swriter(rchan: chan of array of byte, ctl: chan of int, fd: ref Sys->FD)
{
	b: array of byte;

	pid := sys->pctl(0, nil);
	ctl <-= pid;

	while(1){
		b = <- rchan;
		if(b != nil){
			sys->write(fd, b, len b);
			b = nil;
		}
		else
			sys->print("Got nil message in swriter\n");
	}
}

creader(rchan: chan of (array of byte, ref Rmsg), ctl: chan of int, fd: ref Sys->FD)
{
	r: ref Rmsg;

	pid := sys->pctl(0, nil);
	ctl <-= pid;

	while(1){
		(m, e) := styx->readmsg(fd, msize);
		if(e != nil){
			sys->print("readmsg failure in creader: %s\n", e);
			continue;
		}
		if(m != nil){
			(nil, r) = Rmsg.unpack(m);
			if(r != nil)
				rchan <-= (m, r);
		}
#		r = Rmsg.read(fd, msize);
#		if(r != nil){
#			rchan <-= r;
#			r = nil;
#		}
#		else
#			sys->print("Got nil Rmsg in creader\n");
	}
}

cwriter(tchan: chan of array of byte, ctl: chan of int, fd: ref Sys->FD)
{
	b: array of byte;

	pid := sys->pctl(0, nil);
	ctl <-= pid;

	while(1){
		b = <- tchan;
		if(b != nil){
			sys->write(fd, b, len b);
			b = nil;
		}
		else
			sys->print("Got nil Tmsg in cwriter\n");
	}
}

kill(pid: int)
{
	fname := sys->sprint("/prog/%d/ctl", pid);
	fd := sys->open(fname, Sys->OWRITE);
	msg := array of byte "kill";
	sys->write(fd, msg, len msg);
}

showmsg(t: ref Tmsg)
{
	sys->print("%s\n", t.text());
}

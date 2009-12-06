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
outstandingfs, outstandingcache: list of ref Tmsg;
fidqidtab: ref HashTable;

init(nil: ref Draw->Context, args: list of string)
{
	t: ref Tmsg;
	r: ref Rmsg;
	wbfd: ref Sys->FD;

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

	tfs: chan of ref Tmsg;
	rfs: chan of ref Rmsg;
	ctlfs: chan of (int, int);
	fsrpid, fswpid: int;
	if(len args == 2){
		if(dflag)
			sys->fprint(sys->fildes(2), "opening server: %s\n", hd tl args);
		tfs = chan of ref Tmsg;
		rfs = chan of ref Rmsg;
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
	tcache := chan of ref Tmsg;
	rcache := chan of ref Rmsg;
	ctlcache := chan of (int, int);
	cachefs := hd args;

	spawn client(cachefs, tcache, rcache, ctlcache);
	(cacherpid, cachewpid) := <- ctlcache;
	if(cacherpid < 0)
		exit;

	if(dflag)
		sys->fprint(sys->fildes(2), "starting client proc\n");
	tclient := chan of ref Tmsg;
	rclient := chan of ref Rmsg;
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
		t = <- tclient;
		if(t != nil){
			if(!cacheonly)
				procclient(t, rclient, tfs, rfs, tcache, rcache);
			else
				procclientco(t, rclient, tcache, rcache, wbfd);
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

procclient(t: ref Tmsg, rcli: chan of ref Rmsg, fch: chan of ref Tmsg, rfch: chan of ref Rmsg,
	cch: chan of ref Tmsg, rcch: chan of ref Rmsg)
{
	r: ref Rmsg;

	pick x := t {
	Readerror =>
		sys->print("Got Readerror from client: %s\n", x.error);
	Version =>
		fch <-= t;
		cch <-= t;
		<- rcch;
		r = <- rfch;
		rcli <-= r;
	Auth =>
		if(dflag)
			sys->print("Got Auth: afid:%d uname:%s aname:%s\n",
				x.afid, x.uname, x.aname);
	Attach =>
		fch <-= t;
		cch <-= t;
		<- rcch;
		r = <- rfch;
		rcli <-= r;
		pick rr := r {
		Attach =>
			qidstr := sys->sprint("%bd %d %d", rr.qid.path, rr.qid.vers, rr.qid.qtype);
			fidqidtab.insert(string x.fid, HashVal(0, 0.0, qidstr));
		}
	Flush =>
		if(dflag)
			sys->print("Got Flush: oldtag:%d\n", x.oldtag);
		fch <-= t;
		cch <-= t;
		<- rcch;
		r = <- rfch;
		rcli <-= r;
	Walk =>
		if(dflag){
			sys->print("Got Walk: %d %d %d: ", len x.names, x.fid, x.newfid);
			for(i:=0; i < len x.names; ++i)
				sys->print("  %s  ", x.names[i]);
			sys->print("\n");
		}
		fch <-= t;
		cch <-= t;
		cr := <- rcch;
		r = <- rfch;
		pick fr := r {
		Walk =>
			pick ccr := cr {
			Walk =>
				if(dflag)
					sys->print("fr: %d ccr:%d\n", len fr.qids, len ccr.qids);
				lf := len fr.qids;
				if(lf == len ccr.qids)
					rcli <- = r;
				else{
					n := len ccr.qids;
					buildpath(x, fr, n, cch, rcch);
					rcli <-= r;
				}
				if(lf == 0){
					qh := fidqidtab.find(string x.fid);
					if(qh == nil){
						sys->print("fid missing from hash table in walk\n");
					}
					else{
						fidqidtab.insert(string x.newfid, HashVal(0, 0.0, qh.s));
					}
				}
				else if(lf == len x.names){
					q := fr.qids[lf - 1];
					qidstr := sys->sprint("%bd %d %d", q.path, q.vers, q.qtype);
					fidqidtab.insert(string x.newfid, HashVal(0, 0.0, qidstr));
				}
			Error =>
				buildpath(x, fr, 0, cch, rcch);
				rcli <-= r;
			}
		Error =>
			rcli <- = r;
		}
	Open =>
		if(dflag)
			sys->print("Got Open: fid:%d mode:%d\n", x.fid, x.mode);
		fch <-= t;
		stmsg := ref Tmsg.Stat(42, x.fid);
		cch <-= stmsg;
		stresp := <- rcch;
		pick s := stresp {
		Stat =>
			if(s.stat.qid.qtype != Sys->QTDIR)
				x.mode = Sys->ORDWR;
		* =>
			sys->fprint(sys->fildes(2), "Unexpected error in open: %r\n");
		}
		cch <-= t;
		rc := <- rcch;
		pick prc := rc {
		Error =>
			sys->print("Error in open: %s\n", prc.ename);
		}
		r = <- rfch;
		rcli <-= r;
		pick rr := r {
		Open =>
			qidstr := sys->sprint("%bd %d %d", rr.qid.path, rr.qid.vers, rr.qid.qtype);
			fidqidtab.insert(string x.fid, HashVal(0, 0.0, qidstr));
		}
	Create =>
		if(dflag)
			sys->print("Got Create: fid:%d name:%s perm:%uo mode:%d\n",
				x.fid, x.name, x.perm, x.mode);
		fch <-= t;
		cch <-= t;
		<- rcch;
		r = <- rfch;
		rcli <-= r;
		pick rr := r {
		Create =>
			qidstr := sys->sprint("%bd %d %d", rr.qid.path, rr.qid.vers, rr.qid.qtype);
			fidqidtab.insert(string x.fid, HashVal(0, 0.0, qidstr));
		}
	Read =>
		if(dflag)
			sys->print("Got read request: fid:%d offset:%bd size:%d\n",
				x.fid, x.offset, x.count);
		fch <-= t;
		r = <- rfch;
		pick pr := r {
		Read =>
			qt := Sys->QTDIR;
			fq := fidqidtab.find(string x.fid);
			if(fq != nil){
				(n, l) := sys->tokenize(fq.s, " ");
				if(n == 3)
					qt = int hd tl tl l;
				else
					sys->print("Malformed hash entry: %d\n", n);
			}
			if((qt & Sys->QTDIR) == 0){
				twrite := ref Tmsg.Write(42, x.fid, x.offset, pr.data);
				if(twrite != nil){
					cch <-= twrite;
					rc := <- rcch;
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
		rcli <-= r;
	Write =>
		if(dflag)
			sys->print("Got Write: fid:%d offset:%bd size:%d\n",
				x.fid, x.offset, len x.data);
		fch <-= t;
		cch <-= t;
		<- rcch;
		r = <- rfch;
		rcli <-= r;
	Clunk =>
		fch <-= t;
		cch <-= t;
		<- rcch;
		r = <- rfch;
		rcli <-= r;
		fidqidtab.delete(string x.fid);
		if(dflag)
			sys->print("clunked: %d, fidqidtab size: %d\n", x.fid, len fidqidtab.all());
	Remove =>
		if(dflag)
			sys->print("Got Remove: fid:%d\n", x.fid);
		fch <-= t;
		cch <-= t;
		<- rcch;
		r = <- rfch;
		rcli <-= r;
		fidqidtab.delete(string x.fid);
	Stat =>
		if(dflag)
			sys->print("Got Stat: fid: %d ", x.fid);
		fch <-= t;
		r = <- rfch;
		pick pr := r {
		Stat =>
			if(dflag)
				sys->print("mode:%uo len:%bd", pr.stat.mode, pr.stat.length);
			nstat := Sys->nulldir;
			nstat.mode = pr.stat.mode | 8r200;
			nstat.atime = pr.stat.atime;
			nstat.mtime = pr.stat.mtime;
			if((pr.stat.dtype & Sys->DMDIR) == 0)
				nstat.length = pr.stat.length;
			twstat := ref Tmsg.Wstat(42, x.fid, nstat);
			cch <-= twstat;
			<- rcch;
		* =>
			sys->print("Bad stat response\n");
		}
		rcli <-= r;
		if(dflag)
			sys->print("\n");
	Wstat =>
		if(dflag)
			sys->print("Got Wstat: fid:%d\n", x.fid);
		fch <-= t;
		cch <-= t;
		<- rcch;
		r = <- rfch;
		rcli <-= r;
	* =>
		sys->print("Got unknown client message:\n");
		fch <-= t;
		cch <-= t;
		<- rcch;
		r = <- rfch;
		rcli <-= r;
	}
}

buildpath(x: ref Tmsg.Walk, fr: ref Rmsg.Walk, n: int,
	cch: chan of ref Tmsg, rcch: chan of ref Rmsg)
{
	if(dflag)
		sys->fprint(sys->fildes(2), "In buildpath, n=%d\n", n);
	for(i := n; i < len fr.qids - 1; ++i){
		twalk := ref Tmsg.Walk(42, x.fid, 9999, x.names[:i]);
		cch <-= twalk;
		tw := <- rcch;
		if(dflag)
			sys->fprint(sys->fildes(2), "Creating %s in buildpath\n", x.names[i]);
		tcreate := ref Tmsg.Create(42, 9999, x.names[i],
			8r755 | Styx->DMDIR, Sys->OREAD);
		cch <- = tcreate;
		rcreate := <- rcch;
		pick rc2 := rcreate {
		Error =>
			sys->print("Create failed in walk: %s\n", rc2.ename);
			return;
		}
		tclunk := ref Tmsg.Clunk(42, 9999);
		cch <-= tclunk;
		<- rcch;
	}
	twalk := ref Tmsg.Walk(42, x.fid, 9999, x.names[:len fr.qids - 1]);
	cch <-= twalk;
	tw := <- rcch;
	if(fr.qids[len fr.qids-1].qtype & Styx->QTDIR)
		perm := 8r755 | Styx->DMDIR;
	else
		perm = 8r755;
	tcreate := ref Tmsg.Create(42, 9999,
		x.names[len fr.qids-1], perm, Sys->OREAD);
	cch <-= tcreate;
	<- rcch;
	tclunk := ref Tmsg.Clunk(42, 9999);
	cch <-= tclunk;
	<- rcch;
	twalk = ref Tmsg.Walk(42, x.fid, x.newfid, x.names);
	cch <-= twalk;
	tw = <- rcch;
}

procclientco(t: ref Tmsg, rcli: chan of ref Rmsg, 
	cch: chan of ref Tmsg, rcch: chan of ref Rmsg, wbfd: ref Sys->FD)
{
	r: ref Rmsg;
	b: array of byte;

	pick x := t {
	Version =>
		cch <-= t;
		r = <- rcch;
		rcli <-= r;
	Attach =>
		cch <-= t;
		r = <- rcch;
		rcli <-= r;
		if(wbfd != nil){
			b = t.pack();
			sys->write(wbfd, b, len b);
		}
	Flush =>
		cch <-= t;
		r = <- rcch;
		rcli <-= r;
		if(wbfd != nil){
			b = t.pack();
			sys->write(wbfd, b, len b);
		}
	Walk =>
		cch <-= t;
		r = <- rcch;
		rcli <-= r;
		if(wbfd != nil){
			b = t.pack();
			sys->write(wbfd, b, len b);
		}
	Create =>
		cch <-= t;
		r = <- rcch;
		rcli <-= r;
		if(wbfd != nil){
			b = t.pack();
			sys->write(wbfd, b, len b);
		}
	Write =>
		cch <-= t;
		r = <- rcch;
		rcli <-= r;
		if(wbfd != nil){
			b = t.pack();
			sys->write(wbfd, b, len b);
		}
	Wstat =>
		cch <-= t;
		r = <- rcch;
		rcli <-= r;
		if(wbfd != nil){
			b = t.pack();
			sys->write(wbfd, b, len b);
		}
	Open =>
		cch <-= t;
		r = <- rcch;
		rcli <-= r;
		if(wbfd != nil){
			b = t.pack();
			sys->write(wbfd, b, len b);
		}
	Read =>
		cch <-= t;
		r = <- rcch;
		rcli <-= r;
	Stat =>
		cch <-= t;
		r = <- rcch;
		rcli <-= r;
	Clunk =>
		cch <-= t;
		r = <- rcch;
		rcli <-= r;
		if(wbfd != nil){
			b = t.pack();
			sys->write(wbfd, b, len b);
		}
	Remove =>
		cch <-= t;
		r = <- rcch;
		rcli <-= r;
		if(wbfd != nil){
			b = t.pack();
			sys->write(wbfd, b, len b);
		}
	* =>
		sys->print("Got unknown client message\n");
		cch <-= t;
		r = <- rcch;
		rcli <-= r;
	}
}

playback(fch: chan of ref Tmsg, frch: chan of ref Rmsg, fd: ref Sys->FD)
{
	while(1){
		t := Tmsg.read(fd, 0);
		if(t == nil)
			break;
		fch <-= t;
		r := <- frch;
		pick pr := r {
		Error =>
			sys->print("Unexpected error in replay: %r\n");
		}
	}
		
}

servproc(tchan: chan of ref Tmsg, rchan: chan of ref Rmsg, ctl: chan of (int, int))
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

client(addr: string, tchan: chan of ref Tmsg, rchan: chan of ref Rmsg, ctl: chan of (int, int))
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

sreader(tchan: chan of ref Tmsg, ctl: chan of int, fd: ref Sys->FD)
{
	t: ref Tmsg;

	pid := sys->pctl(0, nil);
	ctl <-= pid;

	while(1){
		t = Tmsg.read(fd, msize);
		tchan <-= t;
		t = nil;
	}
}

swriter(rchan: chan of ref Rmsg, ctl: chan of int, fd: ref Sys->FD)
{
	r: ref Rmsg;
	b: array of byte;

	pid := sys->pctl(0, nil);
	ctl <-= pid;

	while(1){
		r = <- rchan;
		if(r != nil){
			b = r.pack();
			if(b != nil){
				sys->write(fd, b, len b);
				b = nil;
			}
			else
				sys->print("r.pack() failed in swriter\n");
			r = nil;
		}
		else
			sys->print("Got nil Rmsg in swriter\n");
	}
}

creader(rchan: chan of ref Rmsg, ctl: chan of int, fd: ref Sys->FD)
{
	r: ref Rmsg;

	pid := sys->pctl(0, nil);
	ctl <-= pid;

	while(1){
		r = Rmsg.read(fd, msize);
		if(r != nil){
			rchan <-= r;
			r = nil;
		}
		else
			sys->print("Got nil Rmsg in creader\n");
	}
}

cwriter(tchan: chan of ref Tmsg, ctl: chan of int, fd: ref Sys->FD)
{
	t: ref Tmsg;
	b: array of byte;

	pid := sys->pctl(0, nil);
	ctl <-= pid;

	while(1){
		t = <- tchan;
		if(t != nil){
			b = t.pack();
			if(b != nil){
				sys->write(fd, b, len b);
				b = nil;
			}
			else
				sys->print("t.pack() failed in cwriter\n");
			t = nil;
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

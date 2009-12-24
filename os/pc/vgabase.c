#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"

#define	Image	IMAGE
#include <draw.h>
#include <memdraw.h>
#include <cursor.h>
#include "screen.h"

static int mode;
static int needredraw;
static Point lastcur = {-1, -1};

static void
basevgaenable(VGAscr *scr)
{
	USED(scr);
}

/*
 * The values here are borrowed from svgalib.
 */
static void
basevgainit(VGAscr *scr)
{
	int cmap16[] = {0, 0, 0, 5, 0, 0, 7, 0, 0, 9, 0, 0, 11, 0, 0,
		5, 5, 5, 0, 7, 0, 7, 7, 7, 0, 9, 0, 0, 11, 0,
		10, 10, 10, 0, 0, 7, 0, 0, 9, 13, 13, 13, 14, 14, 14,
		15, 15, 15};
	Rectangle *r;
	ulong i;

	ilock(&scr->devlock);
	r = &(scr->gscreen->r);
	if(r->max.x - r->min.x == 320 && r->max.y - r->min.y == 200 &&
			scr->gscreen->depth == 8)
		mode = 0x13;
	else 	if(r->max.x - r->min.x == 640 && r->max.y - r->min.y == 480 &&
			scr->gscreen->depth == 4)
		mode = 0x12;
	else
		mode = 13;

	/* Put the sequencer in a reset mode */
	vgaxo(Seqx, 0x00, 0x01);

	/* Program the Misc Output and Sequencer regs */
	if(mode == 0x12)
		vgao(MiscW, 0xe3);
	else
		vgao(MiscW, 0x63);
	vgaxo(Seqx, 0x01, 0x01);
	vgaxo(Seqx, 0x02, 0x0f);
	if(mode == 0x12)
		vgaxo(Seqx, 0x04, 0x06);
	else
		vgaxo(Seqx, 0x04, 0x0e);

	/* Now do the CRTC regs */
	vgaxo(Crtx, 0x11, vgaxi(Crtx, 0x11) & 0x7f);
	vgaxo(Crtx, 0x00, 0x5f);
	vgaxo(Crtx, 0x01, 0x4f);
	vgaxo(Crtx, 0x02, 0x50);
	vgaxo(Crtx, 0x03, 0x82);
	vgaxo(Crtx, 0x04, 0x54);
	vgaxo(Crtx, 0x05, 0x80);
	if(mode == 0x12){
		vgaxo(Crtx, 0x06, 0x0b);
		vgaxo(Crtx, 0x07, 0x03e);
		vgaxo(Crtx, 0x08, 0x00);
		vgaxo(Crtx, 0x09, 0x40);
	}
	else{
		vgaxo(Crtx, 0x06, 0xbf);
		vgaxo(Crtx, 0x07, 0x1f);
		vgaxo(Crtx, 0x08, 0x00);
		vgaxo(Crtx, 0x09, 0x41);
	}
	vgaxo(Crtx, 0x0a, 0x00);
	vgaxo(Crtx, 0x0b, 0x00);
	vgaxo(Crtx, 0x0c, 0x00);
	vgaxo(Crtx, 0x0d, 0x00);
	if(mode == 0x12){
		vgaxo(Crtx, 0x10, 0xea);
		vgaxo(Crtx, 0x11, 0x8c);
		vgaxo(Crtx, 0x12, 0xdf);
		vgaxo(Crtx, 0x13, 0x28);
		vgaxo(Crtx, 0x14, 0x00);
		vgaxo(Crtx, 0x15, 0xe7);
		vgaxo(Crtx, 0x16, 0x04);
		vgaxo(Crtx, 0x17, 0xe3);
	}
	else{
		vgaxo(Crtx, 0x10, 0x9c);
		vgaxo(Crtx, 0x11, 0x8e);
		vgaxo(Crtx, 0x12, 0x8f);
		vgaxo(Crtx, 0x13, 0x28);
		vgaxo(Crtx, 0x14, 0x40);
		vgaxo(Crtx, 0x15, 0x96);
		vgaxo(Crtx, 0x16, 0xb9);
		vgaxo(Crtx, 0x17, 0xa3);
	}

	/* Next the graphics regs */
	vgaxo(Grx, 0x00, 0x00);
	vgaxo(Grx, 0x01, 0x00);
	vgaxo(Grx, 0x02, 0x00);
	vgaxo(Grx, 0x03, 0x00);
	vgaxo(Grx, 0x04, 0x00);
	if(mode == 0x12){
		vgaxo(Grx, 0x05, 0x00);
	}
	else{
		vgaxo(Grx, 0x05, 0x40);
	}
	vgaxo(Grx, 0x06, 0x05);
	vgaxo(Grx, 0x07, 0x0f);
	vgaxo(Grx, 0x08, 0xff);

	/* Finally the Attr regs */
	vgaxo(Attrx, 0x00, 0x00);
	vgaxo(Attrx, 0x01, 0x01);
	vgaxo(Attrx, 0x02, 0x02);
	vgaxo(Attrx, 0x03, 0x03);
	vgaxo(Attrx, 0x04, 0x04);
	vgaxo(Attrx, 0x05, 0x05);
	vgaxo(Attrx, 0x06, 0x06);
	vgaxo(Attrx, 0x07, 0x07);
	vgaxo(Attrx, 0x08, 0x08);
	vgaxo(Attrx, 0x09, 0x09);
	vgaxo(Attrx, 0x0a, 0x0a);
	vgaxo(Attrx, 0x0b, 0x0b);
	vgaxo(Attrx, 0x0c, 0x0c);
	vgaxo(Attrx, 0x0d, 0x0d);
	vgaxo(Attrx, 0x0e, 0x0e);
	vgaxo(Attrx, 0x0f, 0x0f);
	if(mode == 0x12)
		vgaxo(Attrx, 0x10, 0x01);
	else
		vgaxo(Attrx, 0x10, 0x41);
	vgaxo(Attrx, 0x11, 0x00);
	vgaxo(Attrx, 0x12, 0x0f);
	vgaxo(Attrx, 0x13, 0x00);
	vgaxo(Attrx, 0x14, 0x00);

	/* Turn off the reset */
	vgaxo(Seqx, 0x00, 0x03);

	/*
	 * In 640x480x4, there aren't enough colors to make
	 * the default colormap look "palettable" so we're
	 * going to fall back to a predefined colormap.
	 */
	if(mode == 0x12)
		for(i = 0; i < 16; ++i){
			setcolor(i,
				cmap16[3*i] * 0x10101010,
				cmap16[3*i+1] * 0x10101010,
				cmap16[3*i+2] * 0x10101010);
		}
	iunlock(&scr->devlock);
}

static void
basevgaflush(VGAscr *scr, Rectangle r)
{
	int i, j, k, n, rs, incs;
	uchar t, t0, t1, t2, t3;
	Memimage *s;
	uchar *p, *q;
	static uchar *plane0 = nil, *plane1 = nil, *plane2 = nil, *plane3 = nil;

	s = scr->gscreen;
	if(s == nil)
		return;
	if(rectclip(&r, s->r) == 0)
		return;
	incs = s->width * BY2WD;
	if(mode == 0x12){
		/*
		 * Mode 12 uses a screwy memory layout.  The four bits
		 * are divided into four memory planes which are accessed
		 * in parallel through a complex set of masks...
		 */
		if(plane0 == nil){
			i = (s->r.max.y * s->r.max.x + 7) / 8;
			plane0 = malloc(i);
			plane1 = malloc(i);
			plane2 = malloc(i);
			plane3 = malloc(i);
		}

		ilock(&scr->devlock);

		/* Make life easer and deal with full bytes */
		r.min.x &= ~0x07;
		r.max.x = (r.max.x + 7) & ~0x07;
		q = scr->gscreendata->bdata
			+ r.min.y * s->width * BY2WD
			+ (r.min.x * s->depth) / 8;
		rs = r.min.x / 8;
		n= (r.max.x - r.min.x) / 8;

		/* Extract the 4 planes */
		for(j = r.min.y; j < r.max.y; ++j){
			p = q;
			for(i = rs; i < rs + n; ++i){
				t0 = t1 = t2 = t3 = 0;
				for(k = 0; k < 8; ++k){
					t = *p;
					if(k & 01)
						++p;
					else
						t >>= 4;
					t0 = (t0 << 1) | t & 01;
					t >>= 1;
					t1 = (t1 << 1) | t & 01;
					t >>= 1;
					t2 = (t2 << 1) | t & 01;
					t >>= 1;
					t3 = (t3 << 1) | t & 01;
				}
				k = j * 80 + i;
				plane0[k] = t0;
				plane1[k] = t1;
				plane2[k] = t2;
				plane3[k] = t3;
			}
			q += incs;
		}
		/* Copy the planes to video memory */
		for(j = r.min.y; j < r.max.y; j++){
			k = j * 80 + rs;
			p = (uchar *)KADDR(VGAMEM()) + k;
			vgaxo(Seqx, 0x02, 0x01);
			memmove(p, plane0 + k, n);
			vgaxo(Seqx, 0x02, 0x02);
			memmove(p, plane1 + k, n);
			vgaxo(Seqx, 0x02, 0x04);
			memmove(p, plane2 + k, n);
			vgaxo(Seqx, 0x02, 0x08);
			memmove(p, plane3 + k, n);
		}
		iunlock(&scr->devlock);
	}
	else{
		q = scr->gscreendata->bdata
			+ r.min.y * s->width * BY2WD
			+ (r.min.x * s->depth) / 8;
		n = ((r.max.x - r.min.x) * s->depth) / 8;
		ilock(&scr->devlock);
		for(i = r.min.y; i < r.max.y; ++i){
			p = (uchar *)KADDR(VGAMEM()) + 320 * i + r.min.x;
			memmove(p, q, n);
			q += incs;
		}
		iunlock(&scr->devlock);
	}
	if(lastcur.x > r.min.x - CURSWID && lastcur.x < r.max.x
			&& lastcur.y > r.min.y - CURSHGT && lastcur.y < r.max.y)
		needredraw = 1;
}

static Lock gclock;

static void
basegcset(VGAscr *scr, int x, int y)
{
	uchar *p;
	int i, j, k, n, n1, n2, mask, mask1, mask2, latch, pl, cx, cy;
	int maxx, maxy;
	Rectangle r;

	ilock(&gclock);
	if(needredraw == 0 && lastcur.x == x && lastcur.y == y){
		iunlock(&gclock);
		return;
	}
	if(lastcur.x != -1 && lastcur.y != -1){
		r.min.x = lastcur.x;
		r.min.y = lastcur.y;
		r.max.x = lastcur.x + CURSWID;
		r.max.y = lastcur.y + CURSHGT;
		basevgaflush(scr, r);
	}
	if(x + CURSWID < scr->gscreen->r.max.x)
		maxx = CURSWID;
	else
		maxx = scr->gscreen->r.max.x - x;
	if(y + CURSHGT < scr->gscreen->r.max.y)
		maxy = CURSHGT;
	else
		maxy = scr->gscreen->r.max.y - y;
	if(mode == 0x12){
		k = x & 0x07;
		for(pl = 0; pl < 4; ++pl){
			vgaxo(Seqx, 0x02, 1 << pl);
			vgaxo(Grx, 0x04, pl);
			for(cy = 0; cy < maxy; ++cy){
				j = cy * CURSWID / BI2BY;
				p = (uchar *)KADDR(VGAMEM()) + 80 * (y + cy) + x / 8;
				n1 = mask1 = 0;
				for(cx = 0; cx < maxx; cx += 8){
					i = cx / BI2BY;
					n2 = scr->clr[i+j];
					mask2 = scr->clr[i+j] | scr->set[i+j];
					n = (n1 << (8 - k)) | (n2 >> k);
					mask = (mask1 << (8 - k)) | (mask2 >> k);
					n1 = n2;
					mask1 = mask2;
					*p = (*p & ~mask) | (n & mask);
					++p;
				}
				if(k != 0 && maxx == CURSWID){
					n = n1 << (8 - k);
					mask = mask1 << (8 - k);
					*p = (*p & ~mask) | (n & mask);
				}
			}
		}
	}
	else{
		for(cy = 0; cy < maxy; ++cy){
			k = 0;
			j = cy * CURSWID / BI2BY;
			p = (uchar *)KADDR(VGAMEM()) + 320 * (y + cy) + x;
			for(cx = 0; cx < maxx; ++cx){
				i = cx / BI2BY;
				if(scr->clr[i+j] & (0x80 >> k))
					*p = Pwhite;
				else if(scr->set[i+j] & (0x80 >> k))
					*p = Pblack;
				++p;
				if(++k >= 8)
					k = 0;
			}
		}
	}
	lastcur.x = x;
	lastcur.y = y;
	needredraw = 0;
	iunlock(&gclock);
}

static void
basegcload(VGAscr *scr, Cursor *curs)
{
	memmove(&scr->Cursor, curs, sizeof(Cursor));
	basegcset(scr, 0, 0);
}

static void
ptrupdate(void)
{
	cursoron(0);
}

static void
basegcenable(VGAscr *scr)
{
	static int enabled = 0;

	if(enabled == 0){
		basegcload(scr, &arrow);
		addclock0link(ptrupdate, 50);
	}
	else
		print("attempt to enable cursor multiple times\n");
}

static int
basegcmove(VGAscr *scr, Point p)
{
	int x, xo, y, yo;

	x = p.x + scr->offset.x;
	if(x < 0)
		x = 0;
	else if(x >= scr->gscreen->r.max.x - 1)
		x = scr->gscreen->r.max.x - 2;
	y = p.y + scr->offset.y;
	if(y < 0)
		y = 0;
	else if(y >= scr->gscreen->r.max.y - 1)
		y = scr->gscreen->r.max.y - 2;
	basegcset(scr, x, y);
	return 0;
}

VGAdev vgabasedev = {
	"basevga",

	.enable = basevgaenable,
	0,
	0,
	0,
	.drawinit = basevgainit,
	0,
	0,
	0,
	.flush = basevgaflush,
};

VGAcur vgabasecur = {
	"basevgagc",

	.enable = basegcenable,
	0,
	.load = basegcload,
	.move = basegcmove,
	0,
};

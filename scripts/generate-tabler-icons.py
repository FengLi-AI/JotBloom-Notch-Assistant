#!/usr/bin/env python3
"""Regenerate native Tabler paths from the checked-in MIT-licensed SVG sources."""
from pathlib import Path
import re, math, xml.etree.ElementTree as E
p = Path(__file__).resolve().parents[1]
assets = p / 'JotBloom/Resources/Tabler'
# SVG endpoint arcs are converted to cubic Beziers in their original 24-unit canvas.
def parse(d):
 ts=re.findall(r'[a-zA-Z]|[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?',d);i=0;cmd='';x=y=sx=sy=0.;out=[]
 def point(a,b):return f'CGPoint(x: {a:.6f}, y: {b:.6f})'
 def line(a,b):out.append('p.addLine(to: '+point(a,b)+')')
 while i<len(ts):
  if ts[i].isalpha():cmd=ts[i];i+=1
  rel=cmd.islower();c=cmd.lower()
  if c=='z':out.append('p.closeSubpath()');x,y=sx,sy;cmd='';continue
  n={'m':2,'l':2,'h':1,'v':1,'c':6,'a':7}[c];v=list(map(float,ts[i:i+n]));i+=n
  if c in ['m','l']:
   nx=v[0]+(x if rel else 0);ny=v[1]+(y if rel else 0)
   if c=='m':out.append('p.move(to: '+point(nx,ny)+')');sx,sy=nx,ny;cmd='l' if rel else 'L'
   else:line(nx,ny)
   x,y=nx,ny
  elif c=='h':x=v[0]+(x if rel else 0);line(x,y)
  elif c=='v':y=v[0]+(y if rel else 0);line(x,y)
  elif c=='c':
   pts=[(v[k]+(x if rel else 0),v[k+1]+(y if rel else 0)) for k in [0,2,4]]
   out.append('p.addCurve(to: '+point(*pts[2])+', control1: '+point(*pts[0])+', control2: '+point(*pts[1])+')');x,y=pts[2]
  elif c=='a':
   rx,ry,angle,large,sweep,nx,ny=v;nx+=x if rel else 0;ny+=y if rel else 0;rx,ry=abs(rx),abs(ry)
   if not rx or not ry:line(nx,ny);x,y=nx,ny;continue
   if abs(x-nx)+abs(y-ny)<1e-10:continue
   phi=math.radians(angle);co,si=math.cos(phi),math.sin(phi);xp=co*(x-nx)/2+si*(y-ny)/2;yp=-si*(x-nx)/2+co*(y-ny)/2
   lam=xp*xp/(rx*rx)+yp*yp/(ry*ry)
   if lam>1:rx*=math.sqrt(lam);ry*=math.sqrt(lam)
   factor=math.sqrt(max(0,(rx*rx*ry*ry-rx*rx*yp*yp-ry*ry*xp*xp)/(rx*rx*yp*yp+ry*ry*xp*xp)))*(-1 if bool(large)==bool(sweep) else 1)
   cxp=factor*rx*yp/ry;cyp=-factor*ry*xp/rx;cx=co*cxp-si*cyp+(x+nx)/2;cy=si*cxp+co*cyp+(y+ny)/2
   t=math.atan2((yp-cyp)/ry,(xp-cxp)/rx);end=math.atan2((-yp-cyp)/ry,(-xp-cxp)/rx);delta=(end-t)%(2*math.pi)
   if not sweep:delta-=2*math.pi
   count=math.ceil(abs(delta)/(math.pi/2));step=delta/count
   def pos(t):return(cx+co*rx*math.cos(t)-si*ry*math.sin(t),cy+si*rx*math.cos(t)+co*ry*math.sin(t))
   def deriv(t):return(-co*rx*math.sin(t)-si*ry*math.cos(t),-si*rx*math.sin(t)+co*ry*math.cos(t))
   for _ in range(count):
    u=t+step;k=4/3*math.tan(step/4);a=pos(t);b=pos(u);da=deriv(t);db=deriv(u)
    out.append('p.addCurve(to: '+point(*b)+', control1: '+point(a[0]+k*da[0],a[1]+k*da[1])+', control2: '+point(b[0]-k*db[0],b[1]-k*db[1])+')');t=u
   x,y=nx,ny
 return out
cases=[]
for f in sorted(assets.glob('*.svg')):
 if f.name.startswith('._'):continue
 cmds=[]
 for el in E.parse(f).getroot():
  if el.get('stroke')=='none':continue
  if el.tag.split('}')[-1]!='path':raise ValueError((f,el.tag))
  cmds.extend(parse(el.get('d','')))
 cases.append('        case "'+f.stem+'":\n            '+'\n            '.join(cmds))
mapping={'checkmark.circle':'check','tray.full':'archive','leaf':'bulb','lightbulb':'bulb','doc.on.clipboard':'clipboard','text.badge.star':'bookmark','square.stack.3d.up':'archive','bubble.left.and.bubble.right':'message-circle','magnifyingglass':'search','gearshape':'settings-2','slider.horizontal.3':'adjustments-horizontal','rectangle.3.group':'layout-grid','externaldrive':'database','text.bubble':'message-circle','info.circle':'info-circle','chevron.up':'chevron-up','chevron.down':'chevron-down','chevron.left':'chevron-left','chevron.right':'chevron-right','doc.on.doc':'copy','star.fill':'star','square.grid.2x2':'layout-grid','doc.text':'file-text','paintbrush.pointed':'palette','cube':'box','text.alignleft':'align-left','line.3.horizontal':'grip-vertical','line.3.horizontal.decrease.circle':'adjustments-horizontal','network':'world','checkmark':'check','clock.arrow.circlepath':'history','arrow.up':'arrow-up','sun.max':'sun','moon':'moon'}
code='''import SwiftUI

/// Tabler Icons 3.46.0, MIT. Generated from official outline SVGs; vector paths, not raster images.
struct BloomSymbol: View {
    let name: String
    var size: CGFloat = 16
    init(_ name: String, size: CGFloat = 16) { self.name = name; self.size = size }
    private static let aliases: [String: String] = [
'''+',\n'.join('        "'+a+'": "'+b+'"' for a,b in mapping.items())+'''
    ]
    var body: some View {
        BloomIconPath(name: Self.aliases[name] ?? name)
            .stroke(style: StrokeStyle(lineWidth: size * 1.8 / 24, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
private struct BloomIconPath: Shape {
    let name: String
    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch name {
'''+ '\n'.join(cases)+'''
        default: return Path()
        }
        return p.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
    }
}
'''
(p/'JotBloom/Panel/BloomSymbol.swift').write_text(code)
print('generated',len(cases),'vector icons')

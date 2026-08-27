import sys,re
src=sys.argv[1]; dst=sys.argv[2]
out=["/*","  * Automatically generated file; DO NOT EDIT.","  */","#define __KCONFIG_H__ 1",""]
out=["/* Automatically generated - do not edit */"]
for line in open(src):
    line=line.strip()
    if not line or line.startswith('#'): continue
    if '=' not in line: continue
    k,v=line.split('=',1)
    if not k.startswith('CONFIG_'): continue
    if v=='y': out.append(f"#define {k} 1")
    elif v=='m': out.append(f"#define {k}_MODULE 1")
    elif v.startswith('"'): out.append(f"#define {k} {v}")
    elif v=="": out.append(f"#define {k} \"\"")
    else: out.append(f"#define {k} {v}")
open(dst,'w').write("\n".join(out)+"\n")
print("wrote",dst,len(out),"lines")

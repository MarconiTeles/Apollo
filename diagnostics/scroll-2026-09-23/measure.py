import subprocess,time,re,json,sys
name=sys.argv[1]
root=__import__('pathlib').Path(__file__).parent
pid=sys.argv[2] if len(sys.argv)>2 else subprocess.check_output(['pgrep','-x','DayPanel'],text=True).strip()
assert pid.isdecimal(), 'Specify one PID; multiple Apollo instances are running'
f=(root/(name+'.top')).open('w')
p=subprocess.Popen(['top','-l','18','-s','1','-pid',pid,'-pid','419','-stats','pid,cpu,time,threads,mem'],stdout=f)
a=[]
for i in range(18):
 s=subprocess.check_output(['ioreg','-r','-c','IOAccelerator','-d','1','-w','0'],text=True)
 m=re.search(r'"Device Utilization %"=(\d+)',s)
 a.append({'time':time.time(),'gpu':int(m[1]) if m else None})
 time.sleep(1)
p.wait();f.close()
(root/(name+'.gpu.json')).write_text(json.dumps(a))
print(name+' done pid='+pid)

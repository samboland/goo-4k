"""Run the saved single-image chain through an isolated chaiNNer backend.

Keeps processing node settings and wiring; replaces only input paths and adds PNG saving.
"""
import argparse
import hashlib
import json
import time
import urllib.request
from pathlib import Path
from PIL import Image


def request(base,path,data=None):
    body=None if data is None else json.dumps(data).encode()
    req=urllib.request.Request(base+path,data=body,headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=7200) as response:
        return json.load(response)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--chain',type=Path,required=True)
    p.add_argument('--inputs',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--backend',default='http://127.0.0.1:8767')
    p.add_argument('--settings',type=Path,required=True)
    p.add_argument('--resume',action='store_true')
    p.add_argument('--max-output',type=int,default=0)
    p.add_argument('--tile-size',type=int,default=0)
    p.add_argument('--scale',type=int,default=0,help='Force one integer scale for every input')
    p.add_argument('--final-node',help='Explicit final processing node ID, including transparency merge')
    p.add_argument('--scale-resize-node',help='Resize node whose percentage must follow the selected output scale')
    args=p.parse_args()
    args.output.mkdir(parents=True,exist_ok=True)
    raw=args.chain.read_bytes();chain=json.loads(raw)['content']
    digest=hashlib.sha256(raw).hexdigest()
    previous=None
    if (args.output/'report.json').exists():
        if not args.resume:raise ValueError('Existing report requires --resume')
        previous=json.loads((args.output/'report.json').read_text())
        if previous['chain_sha256']!=digest:raise ValueError('Cannot resume with a different chain')
    (args.output/'chain-snapshot.chn').write_bytes(raw)
    registry={n['schemaId']:n for n in request(args.backend,'/nodes')['nodes']}
    nodes={n['id']:n for n in chain['nodes']}
    if args.final_node:
        assert args.final_node in nodes,'Final node not found'
        final=args.final_node
    else:
        final=[n for n in nodes.values() if n['data']['schemaId']=='sam:gimp:mean_curvature_blur']
        assert len(final)==1,'Choose a unique final processing node with --final-node'
        final=final[0]['id']
    # Resolve passthrough nodes: their first output is their first input, so rewire edges around them.
    edges=list(chain['edges'])
    for pid,pnode in nodes.items():
        if not pnode['data'].get('isPassthrough'):continue
        up=[e for e in edges if e['target']==pid]
        up=min(up,key=lambda e:int(e['targetHandle'].rsplit('-',1)[1]))
        for e in edges:
            if e['source']==pid:
                e['source']=up['source'];e['sourceHandle']=up['sourceHandle']
        edges=[e for e in edges if e['target']!=pid]
    chain['edges']=edges
    incoming={(e['target'],int(e['targetHandle'].rsplit('-',1)[1])):e for e in edges}
    active=set()
    def include(node_id):
        if node_id in active:return
        active.add(node_id)
        for (target,_),edge in incoming.items():
            if target==node_id:include(edge['source'])
    include(final)
    if args.scale_resize_node:
        assert args.scale_resize_node in active
        assert nodes[args.scale_resize_node]['data']['schemaId']=='chainner:image:resize'
        assert (args.scale_resize_node,2) not in incoming
    assert all(not nodes[i]['data'].get('isDisabled') and not nodes[i]['data'].get('isPassthrough') for i in active)
    load=[i for i in active if nodes[i]['data']['schemaId']=='chainner:image:load']
    assert len(load)==1
    options=json.loads(args.settings.read_text())['packageSettings']
    report=dict(chain_sha256=hashlib.sha256(raw).hexdigest(),options=options,processing=[nodes[i]['data'] for i in sorted(active)],results=[])
    report['final_node']=final
    if previous:
        assert previous.get('final_node',final)==final,'Cannot resume with a different final node'
        if previous['options']!=options:raise ValueError('Cannot resume with different backend settings')
        report=previous
    inputs=sorted(args.inputs.glob('*.png'))
    report.update(total=len(inputs),status='running')
    report['upcoming_policy']=dict(max_output=args.max_output,tile_size=args.tile_size,scale=args.scale)
    def save_report():
        temp=args.output/'report.tmp.json'
        temp.write_text(json.dumps(report,indent=2))
        temp.replace(args.output/'report.json')
    save_report()
    completed={r['name']:r for r in report['results']}
    for index,source in enumerate(inputs,1):
        destination=args.output/source.name
        source_hash=hashlib.sha256(source.read_bytes()).hexdigest()
        if source.name in completed:
            entry=completed[source.name]
            if entry.get('source_sha256')!=source_hash:raise ValueError('Source changed since completed run')
            with Image.open(destination) as output:
                output.load()
                assert list(output.size)==list(entry['output_size'])
            continue
        if destination.exists():raise FileExistsError(f'Refusing to overwrite {destination}')
        with Image.open(source) as original:
            scale=args.scale or (min(4,args.max_output//max(original.size)) if args.max_output else 4)
        if scale<1:raise ValueError('Native source exceeds output cap')
        report['current']=source.name
        save_report()
        data=[]
        for node_id in sorted(active):
            node=nodes[node_id]['data'];schema=registry[node['schemaId']]
            values=dict(node.get('inputData',{}))
            if node_id==load[0]:values['0']=str(source.resolve())
            if node_id==args.scale_resize_node:values.update({'1':0,'2':scale*100})
            if node['schemaId']=='chainner:pytorch:upscale_image':
                if args.max_output or args.scale:values.update({'4':1,'5':scale})
                if args.tile_size:values['2']=args.tile_size
            inputs_json=[]
            for item in schema['inputs']:
                edge=incoming.get((node_id,item['id']))
                if edge:
                    source_schema=registry[nodes[edge['source']]['data']['schemaId']]
                    output_id=int(edge['sourceHandle'].rsplit('-',1)[1])
                    output_index=next(i for i,o in enumerate(source_schema['outputs']) if o['id']==output_id)
                    inputs_json.append(dict(type='edge',id=edge['source'],index=output_index))
                else:
                    inputs_json.append(dict(type='value',value=values.get(str(item['id']))))
            data.append(dict(id=node_id,schemaId=node['schemaId'],inputs=inputs_json,parent=None,nodeType='regularNode'))
        defaults={1:str(args.output.resolve()),2:None,3:source.stem,4:'png',5:95,6:'BC1_UNORM_SRGB',7:0,8:0,9:0,10:0,11:2167057,12:0,13:0,14:0,15:'u8',16:'u8',17:'4:2:0',18:5,1000:0}
        save_inputs=[dict(type='edge',id=final,index=0) if item['id']==0 else dict(type='value',value=defaults[item['id']]) for item in registry['chainner:image:save']['inputs']]
        data.append(dict(id='batch-save',schemaId='chainner:image:save',inputs=save_inputs,parent=None,nodeType='regularNode'))
        started=time.time()
        print(f'{index}/{len(inputs)} processing {source.name}',flush=True)
        try:
            result=request(args.backend,'/run',dict(data=data,options=options,sendBroadcastData=False))
        except Exception as error:
            report.update(status='error',error=str(error))
            save_report()
            raise
        assert destination.exists(),result
        with Image.open(source) as original,Image.open(destination) as output:
            output.load()
            assert output.size==(original.width*scale,original.height*scale)
            entry=dict(name=source.name,source_sha256=source_hash,source_size=original.size,output_size=output.size,scale=scale,tile_size=args.tile_size,mode=output.mode,seconds=round(time.time()-started,2))
        report['results'].append(entry)
        save_report()
        print(json.dumps(entry),flush=True)
    report.update(status='complete',current=None)
    save_report()


if __name__=='__main__':main()


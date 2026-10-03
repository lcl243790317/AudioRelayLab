"""Keep Windows FAISS/OpenMP out of the PyTorch process; preserve exact FAISS search."""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
import numpy as np

class Index:
    def __init__(self,path):
        self.path=str(Path(path).resolve())
        info=self._run('info')
        self.ntotal=info['ntotal']; self.d=info['d']
    def _run(self,operation,values=None,start=0,count=0,k=0):
        with tempfile.TemporaryDirectory(prefix='rvc-index-') as folder:
            folder=Path(folder)
            if values is not None: np.save(folder/'input.npy',values,allow_pickle=False)
            args=[sys.executable,'-I',str(Path(__file__).with_name('index_worker.py')),
                  self.path,operation,str(folder),str(start),str(count),str(k)]
            result=subprocess.run(args,capture_output=True,text=True,timeout=120)
            if result.returncode: raise RuntimeError('FAISS worker failed: '+result.stderr)
            if operation=='info':return json.loads(result.stdout)
            if operation=='search':
                return (np.load(folder/'distances.npy',allow_pickle=False),np.load(folder/'neighbors.npy',allow_pickle=False))
            return np.load(folder/'vectors.npy',allow_pickle=False)
    def reconstruct_n(self,start,count): return self._run('reconstruct',start=start,count=count)
    def search(self,values,k): return self._run('search',values=values,k=k)

def read_index(path): return Index(path)

"""One FAISS-only subprocess. -I excludes the proxy module and PYTHONPATH."""
import json
import sys
from pathlib import Path
import faiss
import numpy as np

path,operation,folder,start,count,k=sys.argv[1:]
folder=Path(folder);index=faiss.read_index(path)
if operation=='info':print(json.dumps(dict(ntotal=index.ntotal,d=index.d)))
elif operation=='reconstruct':
    np.save(folder/'vectors.npy',index.reconstruct_n(int(start),int(count)),allow_pickle=False)
elif operation=='search':
    values=np.load(folder/'input.npy',allow_pickle=False)
    distances,neighbors=index.search(values,int(k))
    np.save(folder/'distances.npy',distances,allow_pickle=False)
    np.save(folder/'neighbors.npy',neighbors,allow_pickle=False)
else:raise ValueError('Unsupported FAISS operation')

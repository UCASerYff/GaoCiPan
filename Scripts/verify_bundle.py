import hashlib, os, pathlib, sys

def inventory(root):
    result = {}
    root = pathlib.Path(root)
    if root.is_symlink() or not root.is_dir(): raise RuntimeError('Root missing or linked')
    for folder, dirs, files in os.walk(root, followlinks=False, onerror=lambda error: (_ for _ in ()).throw(error)):
        for name in dirs + files:
            path = pathlib.Path(folder)/name
            key = str(path.relative_to(root))
            if path.is_symlink(): raise RuntimeError('Unexpected symlink: '+key)
            if path.is_file():
                h = hashlib.sha256()
                with path.open('rb') as f:
                    for block in iter(lambda:f.read(1024*1024),b''): h.update(block)
                result[key] = {'size':path.stat().st_size,'sha256':h.hexdigest(),'mode':path.stat().st_mode & 0o777}
            elif path.is_dir(): result[key] = {'directory':True,'mode':path.stat().st_mode & 0o777}
            else: raise RuntimeError('Unexpected object: '+key)
    return result

if __name__ == '__main__':
    assert inventory(sys.argv[1]) == inventory(sys.argv[2]), 'Bundle copy mismatch'
    print('逐文件核验通过')

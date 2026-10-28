"""Measure source compiler allocations with 32-bit pointers and 64-bit Ruby integers.

Requires an existing PicoRuby checkout with build/prism generated sources, emcc,
and node. This measures compiler allocations only, not VM/firmware memory.
Usage: python3 test/compiler_memory.py /path/to/picoruby [pico2w3d.rb]
"""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("picoruby", type=Path)
parser.add_argument("source", nargs="?", type=Path, default=Path("pico2w3d.rb"))
args = parser.parse_args()
root = args.picoruby.resolve()
source = args.source.resolve()
out = Path("tmp/compiler_memory").resolve()
out.mkdir(parents=True, exist_ok=True)
if not (root / "build/prism/include/prism/ast.h").is_file():
    parser.error("PicoRuby build/prism generated sources are required; build that checkout first")
print("source SHA256=" + hashlib.sha256(source.read_bytes()).hexdigest(), flush=True)
(out / "allocator.c").write_text(r'''
#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "estalloc.h"
static uint8_t pool[768 * 1024] __attribute__((aligned(8)));
static ESTALLOC *heap;
static unsigned peak;
static void sample(void) {
  /* The allocator calls this after internal realloc allocations, before free. */
  void (*callback)(void) = heap->exit_critical;
  heap->exit_critical = NULL;
  est_take_statistics(heap);
  heap->exit_critical = callback;
  if (heap->stat.used > peak) peak = heap->stat.used;
}
void audit_init(void) {
  heap = est_init(pool, sizeof(pool));
  peak = 0;
  est_set_critical_section(heap, NULL, sample);
}
void *audit_malloc(size_t size) { return est_malloc(heap, size); }
void *audit_calloc(size_t count, size_t size) { return est_calloc(heap, count, size); }
void *audit_realloc(void *old, size_t size) { return est_realloc(heap, old, size); }
void audit_free(void *p) { if (p) est_free(heap, p); }
void audit_self_check(void) {
  audit_init();
  void *old = audit_malloc(1024);
  void *guard = audit_malloc(1024);
  sample();
  unsigned before = heap->stat.used;
  void *grown = audit_realloc(old, 8192);
  assert(grown && grown != old);
  assert(peak >= before + 8192); /* Both the old and new blocks were live. */
  audit_free(grown); audit_free(guard);
}
void audit_report(void) { sample(); printf("POINTER_BITS=%u COMPILER_PEAK=%u COMPILER_RETAINED=%u\n", (unsigned)(sizeof(void*)*8), peak, heap->stat.used); }
''')
(out / "main.c").write_text(r'''
#include "mrc_compile.h"
#include "mrc_dump.h"
void audit_init(void);
void audit_self_check(void);
void audit_report(void);
int main(int argc, char **argv) {
  if (argc != 2) return 2;
  audit_self_check();
  audit_init();
  const char *files[] = { argv[1], NULL };
  uint8_t *source = NULL, *binary = NULL;
  size_t size = 0;
  mrc_ccontext *cc = mrc_ccontext_new(NULL);
  mrc_irep *irep = mrc_load_file_cxt(cc, files, &source);
  if (!irep || mrc_dump_irep(cc, irep, 0, &binary, &size)) return 1;
  printf("BYTECODE=%u\n", (unsigned)size);
  audit_report();
  mrc_irep_free(cc, irep);
  free(source); free(binary);
  mrc_ccontext_free(cc);
  audit_report();
  return 0;
}
''')
compiler = root/'mrbgems/mruby-compiler'
prism = compiler/'lib/prism'
env = dict(os.environ, EM_CACHE=str(out / 'cache'))
flags = ['-O1','-DMRB_NO_GEMS','-DMRC_TARGET_MRUBYC','-DMRBC_ALLOC_LIBC','-DMRBC_INT64','-DMRBC_USE_FLOAT=2','-DMRBC_REQUIRE_32BIT_ALIGNMENT=1','-DMRB_32BIT','-DMRB_INT64','-DMRB_NO_BOXING','-DPRISM_XALLOCATOR','-DPRISM_BUILD_MINIMAL','-DPRISM_DEPTH_MAXIMUM=256', '-Dmalloc=audit_malloc','-Dcalloc=audit_calloc','-Drealloc=audit_realloc','-Dfree=audit_free']
for inc in [root/'include', root/'mrbgems/picoruby-machine/include', root/'include/picoruby', root/'mrbgems/picoruby-mrubyc/lib/mrubyc/src', root/'mrbgems/picoruby-mruby/lib/mruby/include',compiler/'include',root/'build/prism/include',prism/'include']:
    flags.extend(['-I', str(inc)])
sources = list((compiler/'src').glob('*.c'))
parser_sources = {p.name:p for p in (prism/'src').rglob('*.c')}
parser_sources.update({p.name:p for p in (root/'build/prism/src').rglob('*.c')})
sources += list(parser_sources.values()) + [out/'main.c']
objects=[]
for i,src in enumerate(sources):
    obj=out/f'{i}.o'; objects.append(str(obj))
    subprocess.run(['emcc',*flags,'-c',str(src),'-o',str(obj)],env=env,check=True)
for name,src in [('allocator',out/'allocator.c'),('estalloc',root/'mrbgems/picoruby-machine/lib/estalloc/estalloc.c')]:
    obj=out/f'{name}.o';objects.append(str(obj))
    subprocess.run(['emcc','-O1','-I',str(root/'mrbgems/picoruby-machine/lib/estalloc'),'-c',str(src),'-o',str(obj)],env=env,check=True)
subprocess.run(['emcc',*objects,'-sNODERAWFS=1','-sALLOW_MEMORY_GROWTH=1','-sEXIT_RUNTIME=1','-o',str(out/'compile.js')],env=env,check=True)
tiny = out / "tiny.rb"
invalid = out / "invalid.rb"
tiny.write_text("puts 1\n")
invalid.write_text("def broken(\n")
for path, succeeds in [(tiny, True), (invalid, False)]:
    result = subprocess.run(["node", str(out / "compile.js"), str(path)], capture_output=True, text=True)
    assert (result.returncode == 0) == succeeds, result.stdout + result.stderr
    if succeeds:
        assert "POINTER_BITS=32" in result.stdout, result.stdout
print("PASS: valid source compiles; invalid source fails", flush=True)
subprocess.run(["node", str(out / "compile.js"), str(source)], check=True)

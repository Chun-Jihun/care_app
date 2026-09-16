"""Add a locally compiled x86_64 emulator ABI to the pinned upstream arm64 AAR.

The shipping arm64 libraries are byte-for-byte upstream artifacts. Building the
emulator ABI never modifies the Pub cache. See docs/mobile_ai_integration.md.
"""
import zipfile
from scripts.ai_training_common import ROOT, inventory, sha256, write_json

def main():
    source=ROOT/'.tools/pub-cache/hosted/pub.dev/llama_cpp_dart-0.9.0-dev.12/native/android/llama-cpp-dart.aar'
    libraries=ROOT/'.tools/mobile-llama-x64/bin'
    names=['libllama.so','libggml.so','libggml-base.so','libggml-cpu.so']
    target=ROOT/'data/mobile-ai/llama-cpp-dart-with-emulator.aar'
    with zipfile.ZipFile(source) as original, zipfile.ZipFile(target,'w',zipfile.ZIP_DEFLATED) as output:
        for entry in original.infolist():output.writestr(entry,original.read(entry.filename))
        for name in names:output.write(libraries/name,'jni/x86_64/'+name)
        libc=ROOT/'.tools/android-sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/windows-x86_64/sysroot/usr/lib/x86_64-linux-android/libc++_shared.so'
        output.write(libc,'jni/x86_64/libc++_shared.so')
    write_json(ROOT/'experiments/mobile_ai_v1/llama-native.lock.json',dict(
        source_sha256=sha256(source),output_sha256=sha256(target),revision='afeebe103bd99cda8f5dfaefcabadf890db7fda7',
        emulator_libraries=[dict(name=name,sha256=sha256(libraries/name)) for name in names],
        ndk='28.2.13676358',build_type='Release',cpu_threads=2,
        emulator_cpu_flags=['SSE42','AVX','AVX2','FMA','F16C']))
    print(target)

if __name__=='__main__':main()

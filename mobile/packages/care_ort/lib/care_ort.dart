import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'src/bindings/onnxruntime_bindings_generated.dart' as c;

final _library = Platform.isIOS
    ? ffi.DynamicLibrary.process()
    : ffi.DynamicLibrary.open(
        Platform.isWindows
            ? 'onnxruntime.dll'
            : Platform.isMacOS
            ? 'libonnxruntime.dylib'
            : 'libonnxruntime.so',
      );
final _base = c.OnnxRuntimeBindings(_library).OrtGetApiBase();
final _api = _base.ref.GetApi.asFunction<ffi.Pointer<c.OrtApi> Function(int)>()(
  14,
);
void _check(c.OrtStatusPtr status) {
  if (status == ffi.nullptr) return;
  final code = _api.ref.GetErrorCode.asFunction<int Function(c.OrtStatusPtr)>()(
    status,
  );
  _api.ref.ReleaseStatus.asFunction<void Function(c.OrtStatusPtr)>()(status);
  // Raw native diagnostics may contain input metadata; expose an error code only.
  throw StateError('ONNX inference error $code');
}

/// Owns native environment/session. Use only in a worker isolate.
final class FloatSession {
  ffi.Pointer<c.OrtEnv> _env = ffi.nullptr;
  ffi.Pointer<c.OrtSession> _session = ffi.nullptr;
  late String _input, _output;
  FloatSession(String path) {
    try {
      using((arena) {
        final env = arena<ffi.Pointer<c.OrtEnv>>();
        _check(
          _api.ref.CreateEnv
              .asFunction<
                c.OrtStatusPtr Function(
                  int,
                  ffi.Pointer<ffi.Char>,
                  ffi.Pointer<ffi.Pointer<c.OrtEnv>>,
                )
              >()(4, 'care-ocr'.toNativeUtf8(allocator: arena).cast(), env),
        );
        _env = env.value;
        final options = arena<ffi.Pointer<c.OrtSessionOptions>>();
        _check(
          _api.ref.CreateSessionOptions
              .asFunction<
                c.OrtStatusPtr Function(
                  ffi.Pointer<ffi.Pointer<c.OrtSessionOptions>>,
                )
              >()(options),
        );
        try {
          _check(
            _api.ref.SetIntraOpNumThreads
                .asFunction<
                  c.OrtStatusPtr Function(ffi.Pointer<c.OrtSessionOptions>, int)
                >()(options.value, 2),
          );
          _check(
            _api.ref.SetInterOpNumThreads
                .asFunction<
                  c.OrtStatusPtr Function(ffi.Pointer<c.OrtSessionOptions>, int)
                >()(options.value, 1),
          );
          final name = Platform.isWindows
              ? path.toNativeUtf16(allocator: arena).cast<ffi.Char>()
              : path.toNativeUtf8(allocator: arena).cast<ffi.Char>();
          final session = arena<ffi.Pointer<c.OrtSession>>();
          _check(
            _api.ref.CreateSession
                .asFunction<
                  c.OrtStatusPtr Function(
                    ffi.Pointer<c.OrtEnv>,
                    ffi.Pointer<ffi.Char>,
                    ffi.Pointer<c.OrtSessionOptions>,
                    ffi.Pointer<ffi.Pointer<c.OrtSession>>,
                  )
                >()(_env, name, options.value, session),
          );
          _session = session.value;
        } finally {
          _api.ref.ReleaseSessionOptions
              .asFunction<void Function(ffi.Pointer<c.OrtSessionOptions>)>()(
            options.value,
          );
        }
      });
      _input = _name(true);
      _output = _name(false);
    } catch (_) {
      close();
      rethrow;
    }
  }
  String _name(bool input) => using((arena) {
    final count = arena<ffi.Size>();
    final getCount = input
        ? _api.ref.SessionGetInputCount
        : _api.ref.SessionGetOutputCount;
    _check(
      getCount
          .asFunction<
            c.OrtStatusPtr Function(
              ffi.Pointer<c.OrtSession>,
              ffi.Pointer<ffi.Size>,
            )
          >()(_session, count),
    );
    if (count.value != 1) throw StateError('Expected one float tensor');
    final alloc = arena<ffi.Pointer<c.OrtAllocator>>(),
        name = arena<ffi.Pointer<ffi.Char>>();
    _check(
      _api.ref.GetAllocatorWithDefaultOptions
          .asFunction<
            c.OrtStatusPtr Function(ffi.Pointer<ffi.Pointer<c.OrtAllocator>>)
          >()(alloc),
    );
    final getName = input
        ? _api.ref.SessionGetInputName
        : _api.ref.SessionGetOutputName;
    _check(
      getName
          .asFunction<
            c.OrtStatusPtr Function(
              ffi.Pointer<c.OrtSession>,
              int,
              ffi.Pointer<c.OrtAllocator>,
              ffi.Pointer<ffi.Pointer<ffi.Char>>,
            )
          >()(_session, 0, alloc.value, name),
    );
    try {
      return name.value.cast<Utf8>().toDartString();
    } finally {
      alloc.value.ref.Free
          .asFunction<
            void Function(ffi.Pointer<c.OrtAllocator>, ffi.Pointer<ffi.Void>)
          >()(alloc.value, name.value.cast());
    }
  });
  (List<double>, List<int>) run(Float32List input, List<int> shape) {
    if (_session == ffi.nullptr ||
        shape.isEmpty ||
        shape.length > 4 ||
        shape.any((n) => n < 1) ||
        input.length > 3000000 ||
        shape.fold<int>(1, (a, b) => a * b) != input.length) {
      throw StateError('Invalid tensor');
    }
    return using((arena) {
      final memory = arena<ffi.Pointer<c.OrtMemoryInfo>>();
      _check(
        _api.ref.CreateCpuMemoryInfo
            .asFunction<
              c.OrtStatusPtr Function(
                int,
                int,
                ffi.Pointer<ffi.Pointer<c.OrtMemoryInfo>>,
              )
            >()(1, 0, memory),
      );
      final value = arena<ffi.Pointer<c.OrtValue>>(),
          output = arena<ffi.Pointer<c.OrtValue>>();
      final data = arena<ffi.Float>(input.length)
        ..asTypedList(input.length).setAll(0, input);
      final dims = arena<ffi.Int64>(shape.length)
        ..asTypedList(shape.length).setAll(0, shape);
      try {
        _check(
          _api.ref.CreateTensorWithDataAsOrtValue
              .asFunction<
                c.OrtStatusPtr Function(
                  ffi.Pointer<c.OrtMemoryInfo>,
                  ffi.Pointer<ffi.Void>,
                  int,
                  ffi.Pointer<ffi.Int64>,
                  int,
                  int,
                  ffi.Pointer<ffi.Pointer<c.OrtValue>>,
                )
              >()(
            memory.value,
            data.cast(),
            input.length * 4,
            dims,
            shape.length,
            1,
            value,
          ),
        );
      } finally {
        _api.ref.ReleaseMemoryInfo
            .asFunction<void Function(ffi.Pointer<c.OrtMemoryInfo>)>()(
          memory.value,
        );
      }
      try {
        final names = arena<ffi.Pointer<ffi.Char>>()
          ..value = _input.toNativeUtf8(allocator: arena).cast();
        final outputs = arena<ffi.Pointer<ffi.Char>>()
          ..value = _output.toNativeUtf8(allocator: arena).cast();
        _check(
          _api.ref.Run
              .asFunction<
                c.OrtStatusPtr Function(
                  ffi.Pointer<c.OrtSession>,
                  ffi.Pointer<c.OrtRunOptions>,
                  ffi.Pointer<ffi.Pointer<ffi.Char>>,
                  ffi.Pointer<ffi.Pointer<c.OrtValue>>,
                  int,
                  ffi.Pointer<ffi.Pointer<ffi.Char>>,
                  int,
                  ffi.Pointer<ffi.Pointer<c.OrtValue>>,
                )
              >()(_session, ffi.nullptr, names, value, 1, outputs, 1, output),
        );
        final info = arena<ffi.Pointer<c.OrtTensorTypeAndShapeInfo>>();
        _check(
          _api.ref.GetTensorTypeAndShape
              .asFunction<
                c.OrtStatusPtr Function(
                  ffi.Pointer<c.OrtValue>,
                  ffi.Pointer<ffi.Pointer<c.OrtTensorTypeAndShapeInfo>>,
                )
              >()(output.value, info),
        );
        try {
          final type = arena<ffi.Int32>(), rank = arena<ffi.Size>();
          _check(
            _api.ref.GetTensorElementType
                .asFunction<
                  c.OrtStatusPtr Function(
                    ffi.Pointer<c.OrtTensorTypeAndShapeInfo>,
                    ffi.Pointer<ffi.Int32>,
                  )
                >()(info.value, type),
          );
          _check(
            _api.ref.GetDimensionsCount
                .asFunction<
                  c.OrtStatusPtr Function(
                    ffi.Pointer<c.OrtTensorTypeAndShapeInfo>,
                    ffi.Pointer<ffi.Size>,
                  )
                >()(info.value, rank),
          );
          if (type.value != 1 || rank.value < 1 || rank.value > 4) {
            throw StateError('Invalid output tensor');
          }
          final dimensions = arena<ffi.Int64>(rank.value);
          _check(
            _api.ref.GetDimensions
                .asFunction<
                  c.OrtStatusPtr Function(
                    ffi.Pointer<c.OrtTensorTypeAndShapeInfo>,
                    ffi.Pointer<ffi.Int64>,
                    int,
                  )
                >()(info.value, dimensions, rank.value),
          );
          final sizes = dimensions.asTypedList(rank.value).toList(),
              length = sizes.fold<int>(1, (a, b) => a * b);
          if (sizes.any((n) => n < 1) || length > 2000000) {
            throw StateError('Output tensor too large');
          }
          final pointer = arena<ffi.Pointer<ffi.Void>>();
          _check(
            _api.ref.GetTensorMutableData
                .asFunction<
                  c.OrtStatusPtr Function(
                    ffi.Pointer<c.OrtValue>,
                    ffi.Pointer<ffi.Pointer<ffi.Void>>,
                  )
                >()(output.value, pointer),
          );
          return (
            pointer.value.cast<ffi.Float>().asTypedList(length).toList(),
            sizes,
          );
        } finally {
          _api.ref.ReleaseTensorTypeAndShapeInfo
              .asFunction<
                void Function(ffi.Pointer<c.OrtTensorTypeAndShapeInfo>)
              >()(info.value);
        }
      } finally {
        if (value.value != ffi.nullptr) {
          _api.ref.ReleaseValue
              .asFunction<void Function(ffi.Pointer<c.OrtValue>)>()(
            value.value,
          );
        }
        if (output.value != ffi.nullptr) {
          _api.ref.ReleaseValue
              .asFunction<void Function(ffi.Pointer<c.OrtValue>)>()(
            output.value,
          );
        }
      }
    });
  }

  void close() {
    if (_session != ffi.nullptr) {
      _api.ref.ReleaseSession
          .asFunction<void Function(ffi.Pointer<c.OrtSession>)>()(_session);
      _session = ffi.nullptr;
    }
    if (_env != ffi.nullptr) {
      _api.ref.ReleaseEnv.asFunction<void Function(ffi.Pointer<c.OrtEnv>)>()(
        _env,
      );
      _env = ffi.nullptr;
    }
  }
}

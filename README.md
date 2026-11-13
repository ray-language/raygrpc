# raygrpc

Un grpcurl escrito en raylang, y un servidor gRPC de demostración con reflexión. Es una app
de *dogfooding*: existe para ejercitar la parte de raylang que ninguna otra app tocaba —
`net/grpc_client`, `net/grpc_conn`, `net/grpc_server`, `net/grpc_status`, `net/grpc_h2`
(HTTP/2 + HPACK), `std/protobuf` a fondo, `std/json` y TLS con ALPN— y apuntar lo que se
rompe o falta.

```
raygrpc list     -plaintext 127.0.0.1:50999
raygrpc describe -plaintext 127.0.0.1:50999 raygrpc.demo.Everything
raygrpc call     -plaintext -d '{"name": "Ana"}' 127.0.0.1:50999 raygrpc.demo.Greeter/SayHello
raygrpc serve    -port 0 -port-file out/port            # Greeter, Echo, KeyValue + reflexión
raygrpc bench    -plaintext -c 8 -duration 5 127.0.0.1:50999
```

## Estado

| Pieza | Estado | Notas |
|---|---|---|
| Formato wire de protobuf (`src/wire.ray`) | ✅ | varints de 64 bits (negativos = 10 octetos), zigzag, fixed32/64, float de 32 bits a mano, packed, grupos; lector **total**: toda entrada mala es `Err`, nunca un pánico |
| Trait `Message` + `encode`/`decode_into<M: Message>` | ✅ | lo implementan los descriptores, la reflexión y los mensajes de la demo, en VM y nativo |
| Parser de `.proto` (proto3) | ✅ | mensajes anidados, enums, `repeated`, `map<K,V>`, `oneof`, `optional`, imports con rutas, reglas de ámbito de protobuf, opciones (`packed`, `json_name`, `allow_alias`); proto2 y `edition` se rechazan con un error claro |
| Descriptores (`FileDescriptorProto`) | ✅ | **idénticos byte a byte** a `protoc --descriptor_set_out` |
| JSON ↔ protobuf (mapeo proto3 de protojson) | ✅ | **mismos bytes que `protoc --encode`**, mismo JSON que grpcurl (int64 como texto, bytes en base64, enums por nombre, mapas, NaN/Infinity, `-emit-defaults`) |
| `decode-raw` | ✅ | mismo texto que `protoc --decode_raw` |
| `call` unario h2c y TLS | ✅ | por `net/grpc_conn` (por defecto), por el cliente propio (`-client raygrpc`, `-v`, `-insecure`, `-no-alpn`) o por `net/grpc_client` (`-oneshot`) |
| Metadatos (`-H`), plazos (`-max-time` → `grpc-timeout`), estados | ✅ | salida y códigos de salida de grpcurl (`ERROR:` / `-format-error`, 64 + código) |
| `list` / `describe` por reflexión o por `.proto`/`-protoset` | ✅ | `describe` imprime lo mismo que grpcurl |
| Cliente de reflexión (stream bidireccional) | ✅ | sobre `net/grpc_h2`: `net/grpc_conn` es solo unario |
| `serve`: servidor propio sobre `net/grpc_h2` | ✅ | reflexión `grpc.reflection.v1` (y `v1alpha`), metadatos de respuesta (cabeceras y *trailers*), plazos, h2c y TLS |
| `serve -engine net` (`net/grpc_server`) | ⚠️ | unario sin reflexión ni metadatos de respuesta; TLS solo con un `accept` propio + `serve_conn` |
| TLS con grpcurl | ⚠️ | el TLS de servidor de raylang no negocia ALPN: grpc-go ≥ 1.67 lo rechaza salvo con `GRPC_ENFORCE_ALPN_ENABLED=false` (hallazgo) |
| `bench` (fibras concurrentes, VM y nativo) | ✅ | ver Rendimiento |
| Streaming en `call` | ➖ | fuera de alcance: `call` hace métodos unarios (la reflexión sí es un stream) |
| Tipos conocidos (`Timestamp`, `Any`, `Struct`…) con su JSON especial | ➖ | se tratan como mensajes normales |

Pruebas: **33** (`tests/*_test.ray`), todas en verde con `ray test` (VM) y `ray test --native`.
Interoperabilidad: **53** comprobaciones contra grpcurl y protoc (`make interop`), todas en
verde. raylang 1.27.95, net 0.15.0, grpcurl 1.9.4, libprotoc 36.2, macOS (Apple Silicon).

## Uso

```
make build          # ./raygrpc (nativo, --release)
make test           # VM
make test-native    # nativo
make interop        # grpcurl y protoc como oráculos (puertos efímeros)
make bench          # llamadas/s: servidor y cliente, VM y nativo
make fixtures       # regenera con protoc los fixtures de las pruebas
```

Opciones al estilo de grpcurl (`-plaintext`, `-insecure`, `-cacert`, `-d`, `-H`, `-max-time`,
`-proto`, `-import-path`, `-protoset`, `-v`, `-emit-defaults`, `-format-error`), más:

- `-client net|raygrpc|oneshot`: quién lleva la llamada unaria.
- `-no-alpn`: TLS sin ALPN (para servidores TLS de raylang).
- `encode`/`decode TIPO` (JSON ↔ binario por stdin/stdout), `decode-raw`, `protoset -o F`.
- Sin `-proto` ni `-protoset`, `encode`/`decode` usan los `.proto` de la demo embebidos en el
  binario (`[native] embed = ["proto"]`).
- `-cacert F`: `std/net` no deja elegir el almacén de confianza por conexión; raygrpc se
  relanza con `SSL_CERT_FILE=F` (rustls lo lee).

El servidor de demo (`proto/demo.proto`):

- `Greeter/SayHello`: saludo; nombre vacío → `INVALID_ARGUMENT`.
- `Echo/Echo`: devuelve el mensaje y los metadatos recibidos; `code` lo convierte en ese error,
  `delay_ms` en una llamada lenta (respeta el plazo y responde `DEADLINE_EXCEEDED`); las claves
  `echo-*` vuelven como *trailers* y siempre va la cabecera `x-raygrpc-server`.
- `Echo/Roundtrip(Everything)`: decodifica y recodifica con el códec dinámico (todos los tipos).
- `KeyValue/Put|Get|Delete|List`: estado en una fibra actor (los handlers trabajan sobre copias).

## Arquitectura

| Módulo | Qué hace |
|---|---|
| `wire.ray` | formato wire total + trait `Message` |
| `schema.ray` | modelo de descriptores y `Registry` por nombre completo |
| `proto_parser.ray` | `.proto` → `FileDef`, imports, resolución de tipos |
| `descriptor.ray` | `impl wire.Message` para cada tipo del esquema → `FileDescriptorProto` |
| `codec.ray` | JSON ↔ protobuf guiado por el esquema; `decode-raw` |
| `reflection.ray` | mensajes de reflexión (tipados) e índice del servidor |
| `server.ray` | servidor gRPC sobre `net/grpc_h2`: streams, *trailers*, control de flujo |
| `h2client.ray` | cliente sobre `net/grpc_h2`: streams, TLS sin verificar o sin ALPN |
| `loader.ray` | de dónde sale el esquema: `.proto`, `-protoset`, reflexión, embebido |
| `client.ray` | `call`, `list`, `describe` (salida de grpcurl) |
| `serve.ray`, `demo.ray` | `serve` con los dos motores y los servicios de demo |
| `bench.ray` | carga con N fibras, una conexión persistente cada una |

## Oráculos

Solo lo instalado, sin descargar nada:

- **grpcurl 1.9.4** (grpc-go) contra `raygrpc serve`: `list`/`describe` por reflexión, llamadas
  sin `.proto`, con `-proto` y con el `-protoset` que escribe raygrpc, errores, `-format-error`,
  plazos, metadatos (`-v`), h2c y TLS (`-cacert`, `-insecure`), y `-protoset-out` para comparar
  byte a byte los descriptores que sirve la reflexión con los de protoc.
- **protoc**: descriptores, `--encode`, `--decode`, `--decode_raw` (en las pruebas, con fixtures
  generados por `scripts/fixtures.sh`, y en vivo en `make interop`).
- **cliente raygrpc → servidor raygrpc**, en VM y nativo. No hay ningún servidor gRPC de
  terceros disponible (ni grpc-go, ni grpcio, Docker parado), así que **el lado cliente solo
  se ha comprobado contra el servidor de raygrpc y contra los bytes de protoc**.

## Rendimiento

`make bench` (Greeter/SayHello, h2c, 8 fibras × 1 conexión persistente, 3 s por fila,
MacBook Apple Silicon, todo en la misma máquina):

| Servidor | Cliente | llamadas/s | p50 | p99 |
|---|---|---:|---:|---:|
| nativo, motor raygrpc | nativo, `net/grpc_conn` | 30 131 | 237 µs | 465 µs |
| nativo, motor raygrpc | nativo, cliente raygrpc | 30 216 | 239 µs | 685 µs |
| nativo, motor raygrpc | VM, `net/grpc_conn` | 9 926 | 800 µs | 1 301 µs |
| nativo, `net/grpc_server` | nativo, `net/grpc_conn` | 46 226 | 152 µs | 338 µs |
| nativo, `net/grpc_server` | nativo, cliente raygrpc | 45 771 | 152 µs | 353 µs |
| nativo, `net/grpc_server` | VM, `net/grpc_conn` | 10 151 | 783 µs | 1 259 µs |
| VM, motor raygrpc | nativo, `net/grpc_conn` | 10 084 | 818 µs | 1 315 µs |
| VM, motor raygrpc | VM, `net/grpc_conn` | 8 173 | 953 µs | 1 649 µs |
| VM, `net/grpc_server` | nativo, `net/grpc_conn` | 10 104 | 819 µs | 1 316 µs |
| VM, `net/grpc_server` | VM, `net/grpc_conn` | 8 294 | 937 µs | 1 648 µs |

Lectura: cualquier extremo en la VM fija el techo en ~10 000 llamadas/s; en nativo el
servidor de `net` (46 000/s) le saca un 50 % al propio (30 000/s), que paga mapas de
metadatos, `Answer` y la decodificación tipada en cada llamada. Los dos clientes nativos
rinden igual.

## Hallazgos de dogfood

Borradores entregados para `findings/` (los números los pone `tools/findings`):

1. **[B] TLS de servidor sin ALPN.** `net.tls_accept` no anuncia `h2`: grpcurl (grpc-go ≥ 1.67)
   rechaza cualquier servidor gRPC-sobre-TLS de raylang («missing selected ALPN property»), y
   los clientes de raylang (`tls_connect_h2`, `grpc_conn.connect_tls`, `grpc_client`) rechazan
   a los servidores de raylang («the server did not negotiate HTTP/2»). No hay gRPC por TLS
   raylang↔raylang con los clientes de `net`; raygrpc lo rodea con `-no-alpn`.
2. **[E] `net/grpc_server` es solo unario** y espera al final del stream antes de despachar:
   una llamada de streaming (la reflexión de grpcurl `list`/`describe`) se cuelga hasta el plazo
   del cliente (sin plazo, para siempre); una ruta desconocida no se rechaza en las cabeceras.
   Tampoco hay listener TLS (solo h2c).
3. **[E] `net/grpc_server`: un handler no puede mandar metadatos** (cabeceras ni *trailers*):
   `Handler = fn(Call) -> Result<bytes, Status>`.
4. **[E] Clientes gRPC de `net`**: `grpc_conn` es solo unario, sin opciones TLS (ni CA propia
   salvo `SSL_CERT_FILE` del proceso, ni `insecure`, ni sin ALPN) y mezcla cabeceras y
   *trailers*; `grpc_client.grpc_call` es solo TLS, sin metadatos, sin plazo y sin
   `grpc-message`.
5. **[B] `std/protobuf.parse` no es total**: un varint o fixed truncado es un error de ejecución
   (índice fuera de rango), un campo length-delimited truncado devuelve `Ok` con menos bytes,
   acepta el campo 0, y un varint de 11 octetos da `Ok(-1)` en la VM y *panic* de Rust en
   nativo («attempt to shift left with overflow»).
6. **[D] `std/protobuf.write_varint` aconseja `write_fixed64` para enteros con signo**: es otro
   tipo wire; para un `int32`/`int64` el receptor lo trata como campo desconocido. Faltan
   zigzag, packed, float/double, varints negativos y un lector con cursor.
7. **[E] `std/math` no convierte a binary32** (`float32` de protobuf): raygrpc lo hace a mano.
8. **[B/D] Un trait cualificado no vale como bound**: `fn f<T: m.Codec>` es error de sintaxis,
   mientras `impl m.Codec for X` sí funciona; hay que `from m import Codec`.

Positivo: los genéricos con trait entre módulos (`impl wire.Message for schema.FieldDef` en un
tercer módulo, `decode_into<M: Message>`) funcionan a la primera en VM y nativo; `u64` resuelve
el texto de los enteros sin signo; `net/grpc_h2` basta para escribir un servidor y un cliente
con streaming; el HPACK de `net` decodifica las cabeceras Huffman de grpc-go; un handler que
hace *panic* en `net/grpc_server` se convierte en `INTERNAL` sin tumbar el servidor; las 33
pruebas pasan en nativo a la primera.

## Licencia

Apache-2.0.

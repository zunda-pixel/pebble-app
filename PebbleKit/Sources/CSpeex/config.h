/* Speex as this app builds it: the decoder half of libspeex 1.2.1, set up the
   way the watch's encoder is (fixed-point, no floating-point API, no VBR) so
   both ends do the same arithmetic. The upstream sources are unmodified; this
   file and the module map are the only additions. See COPYING. */

#ifndef CONFIG_H
#define CONFIG_H

#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STDIO_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_MALLOC 1
#define HAVE_MEMCPY 1
#define HAVE_MEMMOVE 1
#define HAVE_MEMSET 1

#define EXPORT

/* The watch encodes in fixed point. Decoding the same way keeps the two ends
   arithmetically identical, and needs no libm. */
#define FIXED_POINT 1
#define DISABLE_FLOAT_API 1
#define DISABLE_VBR 1

/* Clang has variable-length arrays, so the codec needs no alloca and no
   preallocated scratch. */
#define VAR_ARRAYS 1

#define SIZEOF_INT 4
#define SIZEOF_LONG 8
#define SIZEOF_SHORT 2

#define VERSION "1.2.1"

#endif /* CONFIG_H */

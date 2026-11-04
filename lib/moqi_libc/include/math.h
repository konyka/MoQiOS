/* math.h — the double-precision functions whose results are exactly defined, and the classification macros.
 *
 * Provided: sqrt, fabs, copysign, floor, ceil, trunc, round, rint, nearbyint, lround, llround, lrint, llrint, fmod, remainder,
 * remquo, fmax, fmin, fdim, nextafter, ldexp, scalbn, frexp, modf, and fpclassify, isnan, isinf, isfinite, isnormal, signbit,
 * the ordered-comparison macros. Every one of them returns exactly what glibc returns, bit for bit, on the calls that were
 * measured (host_tests/test_math_abi.c, about 22000 of them, with the NaN-propagation and errno rules included).
 *
 * Not provided yet: the float and long double variants (sqrtf, floorl, ...), fma, and the transcendental functions (sin, cos,
 * tan, exp, log, pow, atan, ...), whose correct rounding is a project of its own.
 *
 * Errors follow glibc: errno is set to EDOM for sqrt of a negative number and fmod/remainder of a zero divisor or an infinite
 * dividend, and to ERANGE when ldexp/scalbn/nextafter/fdim overflow or underflow to zero; the floating-point exception flags
 * are not raised, so math_errhandling is MATH_ERRNO only. The rounding functions assume the default rounding mode (nearest,
 * ties to even), which nothing in this libc changes. lround/lrint of a value that does not fit a long (or of a NaN) return
 * LONG_MIN and leave errno alone, as glibc does.
 */
#ifndef MOQI_MATH_H
#define MOQI_MATH_H

#define HUGE_VAL (__builtin_huge_val())
#define HUGE_VALF (__builtin_huge_valf())
#define INFINITY (__builtin_inff())
#define NAN (__builtin_nanf(""))

#define FP_NAN 0
#define FP_INFINITE 1
#define FP_ZERO 2
#define FP_SUBNORMAL 3
#define FP_NORMAL 4

#define MATH_ERRNO 1
#define MATH_ERREXCEPT 2
#define math_errhandling MATH_ERRNO

#define M_E 2.7182818284590452354
#define M_LOG2E 1.4426950408889634074
#define M_LOG10E 0.43429448190325182765
#define M_LN2 0.69314718055994530942
#define M_LN10 2.30258509299404568402
#define M_PI 3.14159265358979323846
#define M_PI_2 1.57079632679489661923
#define M_PI_4 0.78539816339744830962
#define M_1_PI 0.31830988618379067154
#define M_2_PI 0.63661977236758134308
#define M_2_SQRTPI 1.12837916709551257390
#define M_SQRT2 1.41421356237309504880
#define M_SQRT1_2 0.70710678118654752440

typedef float float_t;
typedef double double_t;

#define fpclassify(x) __builtin_fpclassify(FP_NAN, FP_INFINITE, FP_NORMAL, FP_SUBNORMAL, FP_ZERO, x)
#define isnan(x) __builtin_isnan(x)
#define isinf(x) __builtin_isinf_sign(x)
#define isfinite(x) __builtin_isfinite(x)
#define isnormal(x) __builtin_isnormal(x)
#define signbit(x) __builtin_signbit(x)
#define isgreater(x, y) __builtin_isgreater(x, y)
#define isgreaterequal(x, y) __builtin_isgreaterequal(x, y)
#define isless(x, y) __builtin_isless(x, y)
#define islessequal(x, y) __builtin_islessequal(x, y)
#define islessgreater(x, y) __builtin_islessgreater(x, y)
#define isunordered(x, y) __builtin_isunordered(x, y)

double sqrt(double x);
double fabs(double x);
double copysign(double x, double y);

double floor(double x);
double ceil(double x);
double trunc(double x);
double round(double x);
double rint(double x);
double nearbyint(double x);

long lround(double x);
long long llround(double x);
long lrint(double x);
long long llrint(double x);

double fmod(double x, double y);
double remainder(double x, double y);
double remquo(double x, double y, int *quo);

double fmax(double x, double y);
double fmin(double x, double y);
double fdim(double x, double y);
double nextafter(double x, double y);

double ldexp(double x, int n);
double scalbn(double x, int n);
double frexp(double x, int *exp);
double modf(double x, double *iptr);

#endif /* MOQI_MATH_H */

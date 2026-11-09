/*
 * fp32_adder_tree_5to1_model.c
 * ---------------------------------------------------------------------------
 * Software model of RTL module:
 *     rtl/smc/fp32addtree5to1/fp32_adder_tree_final_pipeline_5to1.v
 *
 * Simplified version: keeps only the data-splitting / repacking topology of
 * the RTL, and uses the host C library's native FP32 addition (`float +`)
 * for the actual arithmetic.  Useful as a reference / golden model when
 * bit-exact IEEE-754 behavior is not required.
 *
 * Functional summary
 * ------------------
 *   8 parallel 5-input FP32 adders.
 *   For channel i in [0..7]:
 *       add_result[i] = Si[0] + Si[1] + Si[2] + Si[3] + old_i
 *     where:
 *       Si is the 128-bit source register i, split into 4 FP32 lanes:
 *           Si = { Si[3], Si[2], Si[1], Si[0] }    (lane 0 = bits[31:0])
 *       old_i is the previous result of channel i (accumulator feedback)
 *
 *   Outputs (128-bit each, packed as 4 x FP32 lanes):
 *       D0 = { add_result[3], add_result[2], add_result[1], add_result[0] }
 *       D1 = { add_result[7], add_result[6], add_result[5], add_result[4] }
 *
 * Build:
 *   gcc -std=c99 -O2 -Wall -Wextra fp32_adder_tree_5to1_model.c -o fp32_addtree
 * (define FP32_ADDTREE_MAIN to build the demo main())
 * ---------------------------------------------------------------------------
 */

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define NUM_INPUTS_PER_ADDER  5
#define NUM_CHANNELS          8

/* =====================================================================
 * 128-bit container: 4 x FP32 lanes (little-endian lane order)
 *   lane[0] = bits[ 31:  0]
 *   lane[1] = bits[ 63: 32]
 *   lane[2] = bits[ 95: 64]
 *   lane[3] = bits[127: 96]
 * ===================================================================== */
typedef struct {
    uint32_t lane[4];
} u128_t;

static inline uint32_t u128_get_lane(const u128_t *v, int j) { return v->lane[j & 3]; }
static inline void     u128_set_lane(u128_t *v, int j, uint32_t x) { v->lane[j & 3] = x; }

/* =====================================================================
 * FP32 <-> uint32_t bit-cast helpers
 * ===================================================================== */
static inline float u2f(uint32_t u)
{
    float f;
    memcpy(&f, &u, sizeof f);
    return f;
}
static inline uint32_t f2u(float f)
{
    uint32_t u;
    memcpy(&u, &f, sizeof u);
    return u;
}

/* =====================================================================
 * Single 5-input FP32 adder using native float arithmetic.
 *   add = in[0] + in[1] + in[2] + in[3] + in[4]
 * (Order is left-to-right; for strict tree summation rearrange as needed.)
 * ===================================================================== */
static uint32_t fp32_add5(const uint32_t in[NUM_INPUTS_PER_ADDER])
{
    float acc = u2f(in[0]);
    for (int k = 1; k < NUM_INPUTS_PER_ADDER; ++k) {
        acc += u2f(in[k]);
    }
    return f2u(acc);
}

/* =====================================================================
 * Top-level: 8 channels x 5-input adder, one step.
 *
 *   Inputs:
 *     s[0..7]              : 8 source registers, each 4 x FP32
 *     *d0, *d1             : current accumulator (also used as `old_i`)
 *
 *   Action per channel i:
 *     old_i           = (i<4) ? d0->lane[i] : d1->lane[i-4]
 *     add_result[i]   = Si[0] + Si[1] + Si[2] + Si[3] + old_i
 *
 *   After the step:
 *     d0->lane[k]     = add_result[k]      (k = 0..3)
 *     d1->lane[k]     = add_result[k+4]    (k = 0..3)
 * ===================================================================== */
void fp32_adder_tree_5to1_step(const u128_t s[NUM_CHANNELS],
                               u128_t   *d0,
                               u128_t   *d1)
{
    uint32_t add_result[NUM_CHANNELS];

    for (int i = 0; i < NUM_CHANNELS; ++i) {
        /* Feedback accumulator (old_i) */
        uint32_t old_i = (i < 4) ? u128_get_lane(d0, i)
                                  : u128_get_lane(d1, i - 4);

        /* Split Si into 4 x FP32 + old_i -> 5 inputs */
        uint32_t inputs[NUM_INPUTS_PER_ADDER] = {
            u128_get_lane(&s[i], 0),
            u128_get_lane(&s[i], 1),
            u128_get_lane(&s[i], 2),
            u128_get_lane(&s[i], 3),
            old_i,
        };

        add_result[i] = fp32_add5(inputs);
    }

    /* Repack D0 / D1 */
    for (int k = 0; k < 4; ++k) {
        u128_set_lane(d0, k, add_result[k]);
        u128_set_lane(d1, k, add_result[k + 4]);
    }
}

/* =====================================================================
 * Demo main (build with -DFP32_ADDTREE_MAIN)
 * ===================================================================== */
#ifdef FP32_ADDTREE_MAIN
static void print_d(const char *name, const u128_t *v)
{
    printf("  %s = [ ", name);
    for (int k = 3; k >= 0; --k) printf("%.6g ", (double)u2f(u128_get_lane(v, k)));
    printf("]\n");
}

int main(void)
{
    u128_t s[NUM_CHANNELS];
    for (int i = 0; i < NUM_CHANNELS; ++i) {
        for (int k = 0; k < 4; ++k) {
            float v = (float)(i + 1) * (float)(k + 1) * 0.5f;
            u128_set_lane(&s[i], k, f2u(v));
        }
    }

    u128_t d0 = {{0,0,0,0}};
    u128_t d1 = {{0,0,0,0}};

    printf("Inputs:\n");
    for (int i = 0; i < NUM_CHANNELS; ++i) {
        printf("  S%d = [ ", i);
        for (int k = 3; k >= 0; --k) printf("%.4g ", (double)u2f(u128_get_lane(&s[i], k)));
        printf("]\n");
    }

    fp32_adder_tree_5to1_step(s, &d0, &d1);
    printf("\nAfter step 1, expected = sum(Si[0..3]):\n");
    print_d("D0", &d0);
    print_d("D1", &d1);

    fp32_adder_tree_5to1_step(s, &d0, &d1);
    printf("\nAfter step 2, expected = 2 * sum(Si[0..3]):\n");
    print_d("D0", &d0);
    print_d("D1", &d1);

    return 0;
}
#endif /* FP32_ADDTREE_MAIN */

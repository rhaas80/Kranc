/*  File produced by Kranc */

#define KRANC_C

#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "cctk.h"
#include "cctk_Arguments.h"
#include "cctk_Parameters.h"
#include "GenericFD.h"
#include "Differencing.h"

/* Define macros used in calculations */
#define INITVALUE (42)
#define QAD(x) (SQR(SQR(x)))
#define INV(x) ((1.0) / (x))
#define SQR(x) ((x) * (x))
#define CUB(x) ((x) * (x) * (x))

static void EM_evol_Body(cGH const * restrict const cctkGH, int const dir, int const face, CCTK_REAL const normal[3], CCTK_REAL const tangentA[3], CCTK_REAL const tangentB[3], int const min[3], int const max[3], int const n_subblock_gfs, CCTK_REAL * restrict const subblock_gfs[])
{
  DECLARE_CCTK_ARGUMENTS;
  DECLARE_CCTK_PARAMETERS;
  
  
  /* Declare the variables used for looping over grid points */
  CCTK_INT i, j, k;
  // CCTK_INT index = INITVALUE;
  
  /* Declare finite differencing variables */
  
  if (verbose > 1)
  {
    CCTK_VInfo(CCTK_THORNSTRING,"Entering EM_evol_Body");
  }
  
  if (cctk_iteration % EM_evol_calc_every != EM_evol_calc_offset)
  {
    return;
  }
  
  const char *groups[] = {"EM::B_group","EM::B_grouprhs","EM::El_group","EM::El_grouprhs"};
  GenericFD_AssertGroupStorage(cctkGH, "EM_evol", 4, groups);
  
  GenericFD_EnsureStencilFits(cctkGH, "EM_evol", 1, 1, 1);
  
  /* Include user-supplied include files */
  
  /* Initialise finite differencing variables */
  ptrdiff_t const di = 1;
  ptrdiff_t const dj = CCTK_GFINDEX3D(cctkGH,0,1,0) - CCTK_GFINDEX3D(cctkGH,0,0,0);
  ptrdiff_t const dk = CCTK_GFINDEX3D(cctkGH,0,0,1) - CCTK_GFINDEX3D(cctkGH,0,0,0);
  CCTK_REAL const dx = ToReal(CCTK_DELTA_SPACE(0));
  CCTK_REAL const dy = ToReal(CCTK_DELTA_SPACE(1));
  CCTK_REAL const dz = ToReal(CCTK_DELTA_SPACE(2));
  CCTK_REAL const dt = ToReal(CCTK_DELTA_TIME);
  CCTK_REAL const dxi = INV(dx);
  CCTK_REAL const dyi = INV(dy);
  CCTK_REAL const dzi = INV(dz);
  CCTK_REAL const khalf = 0.5;
  CCTK_REAL const kthird = 1/3.0;
  CCTK_REAL const ktwothird = 2.0/3.0;
  CCTK_REAL const kfourthird = 4.0/3.0;
  CCTK_REAL const keightthird = 8.0/3.0;
  CCTK_REAL const hdxi = 0.5 * dxi;
  CCTK_REAL const hdyi = 0.5 * dyi;
  CCTK_REAL const hdzi = 0.5 * dzi;
  
  /* Initialize predefined quantities */
  CCTK_REAL const p1o1 = 1;
  CCTK_REAL const p1o12dx = 0.0833333333333333333333333333333*INV(dx);
  CCTK_REAL const p1o12dy = 0.0833333333333333333333333333333*INV(dy);
  CCTK_REAL const p1o12dz = 0.0833333333333333333333333333333*INV(dz);
  CCTK_REAL const p1o144dxdy = 0.00694444444444444444444444444444*INV(dx)*INV(dy);
  CCTK_REAL const p1o144dxdz = 0.00694444444444444444444444444444*INV(dx)*INV(dz);
  CCTK_REAL const p1o144dydz = 0.00694444444444444444444444444444*INV(dy)*INV(dz);
  CCTK_REAL const p1o2dx = 0.5*INV(dx);
  CCTK_REAL const p1o2dy = 0.5*INV(dy);
  CCTK_REAL const p1o2dz = 0.5*INV(dz);
  CCTK_REAL const p1o4dxdy = 0.25*INV(dx)*INV(dy);
  CCTK_REAL const p1o4dxdz = 0.25*INV(dx)*INV(dz);
  CCTK_REAL const p1o4dydz = 0.25*INV(dy)*INV(dz);
  CCTK_REAL const p1odx = INV(dx);
  CCTK_REAL const p1odx2 = INV(SQR(dx));
  CCTK_REAL const p1ody = INV(dy);
  CCTK_REAL const p1ody2 = INV(SQR(dy));
  CCTK_REAL const p1odz = INV(dz);
  CCTK_REAL const p1odz2 = INV(SQR(dz));
  CCTK_REAL const pm1o12dx2 = -0.0833333333333333333333333333333*INV(SQR(dx));
  CCTK_REAL const pm1o12dy2 = -0.0833333333333333333333333333333*INV(SQR(dy));
  CCTK_REAL const pm1o12dz2 = -0.0833333333333333333333333333333*INV(SQR(dz));
  
  /* Loop over the grid points */
  for (k = min[2]; k < max[2]; k++)
  {
    for (j = min[1]; j < max[1]; j++)
    {
      for (i = min[0]; i < max[0]; i++)
      {
         int  const  index  =  CCTK_GFINDEX3D(cctkGH,i,j,k) ;
        
        /* Assign local copies of grid functions */
        
        CCTK_REAL B1L = B1[index];
        CCTK_REAL B2L = B2[index];
        CCTK_REAL B3L = B3[index];
        CCTK_REAL El1L = El1[index];
        CCTK_REAL El2L = El2[index];
        CCTK_REAL El3L = El3[index];
        
        
        /* Include user supplied include files */
        
        /* Precompute derivatives */
        CCTK_REAL const PDstandard2nd2B1 = PDstandard2nd2(&B1[index]);
        CCTK_REAL const PDstandard2nd3B1 = PDstandard2nd3(&B1[index]);
        CCTK_REAL const PDstandard2nd1B2 = PDstandard2nd1(&B2[index]);
        CCTK_REAL const PDstandard2nd3B2 = PDstandard2nd3(&B2[index]);
        CCTK_REAL const PDstandard2nd1B3 = PDstandard2nd1(&B3[index]);
        CCTK_REAL const PDstandard2nd2B3 = PDstandard2nd2(&B3[index]);
        CCTK_REAL const PDstandard2nd2El1 = PDstandard2nd2(&El1[index]);
        CCTK_REAL const PDstandard2nd3El1 = PDstandard2nd3(&El1[index]);
        CCTK_REAL const PDstandard2nd1El2 = PDstandard2nd1(&El2[index]);
        CCTK_REAL const PDstandard2nd3El2 = PDstandard2nd3(&El2[index]);
        CCTK_REAL const PDstandard2nd1El3 = PDstandard2nd1(&El3[index]);
        CCTK_REAL const PDstandard2nd2El3 = PDstandard2nd2(&El3[index]);
        
        /* Calculate temporaries and grid functions */
        CCTK_REAL El1rhsL = PDstandard2nd2B3 - PDstandard2nd3B2;
        
        CCTK_REAL El2rhsL = -PDstandard2nd1B3 + PDstandard2nd3B1;
        
        CCTK_REAL El3rhsL = PDstandard2nd1B2 - PDstandard2nd2B1;
        
        CCTK_REAL B1rhsL = -PDstandard2nd2El3 + PDstandard2nd3El2;
        
        CCTK_REAL B2rhsL = PDstandard2nd1El3 - PDstandard2nd3El1;
        
        CCTK_REAL B3rhsL = -PDstandard2nd1El2 + PDstandard2nd2El1;
        
        /* Copy local copies back to grid functions */
        B1rhs[index] = B1rhsL;
        B2rhs[index] = B2rhsL;
        B3rhs[index] = B3rhsL;
        El1rhs[index] = El1rhsL;
        El2rhs[index] = El2rhsL;
        El3rhs[index] = El3rhsL;
      }
    }
  }
}

extern "C" void EM_evol(CCTK_ARGUMENTS)
{
  DECLARE_CCTK_ARGUMENTS;
  DECLARE_CCTK_PARAMETERS;
  
  GenericFD_LoopOverEverything(cctkGH, &EM_evol_Body);
}

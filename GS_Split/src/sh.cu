#include "stdio.h"
#include <cuda.h>
#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#define GLM_FORCE_CUDA
#include <glm/glm.hpp>
#include <cooperative_groups.h>
#include <cooperative_groups/reduce.h>
namespace cg = cooperative_groups;


// Spherical harmonics coefficients
__device__ const float SH_C0 = 0.28209479177387814f;
__device__ const float SH_C1 = 0.4886025119029199f;
__device__ const float SH_C2[] = {
	1.0925484305920792f,
	-1.0925484305920792f,
	0.31539156525252005f,
	-1.0925484305920792f,
	0.5462742152960396f
};
__device__ const float SH_C3[] = {
	-0.5900435899266435f,
	2.890611442640554f,
	-0.4570457994644658f,
	0.3731763325901154f,
	-0.4570457994644658f,
	1.445305721320277f,
	-0.5900435899266435f
};


// Forward method for converting the input spherical harmonics
// coefficients of each Gaussian to a simple RGB color.
__global__ void ComputeColorFromSHForwardCUDAKernel(
    const int P, const int deg, const int max_coeffs, 
    const glm::vec3* dirs, 
    const glm::vec3* shs, 
	const bool* visibility_filter,
    glm::vec3* colors, 
    bool* clamped)
{
    auto idx = cg::this_grid().thread_rank();
	if (idx >= P || !visibility_filter[idx])
		return;

	// The implementation is loosely based on code for 
	// "Differentiable Point-Based Radiance Fields for 
	// Efficient View Synthesis" by Zhang et al. (2022)
	glm::vec3 dir = dirs[idx];

	const glm::vec3* sh = shs + idx * max_coeffs;
	glm::vec3 result = SH_C0 * sh[0];

	if (deg > 0)
	{
		float x = dir.x;
		float y = dir.y;
		float z = dir.z;
		result = result - SH_C1 * y * sh[1] + SH_C1 * z * sh[2] - SH_C1 * x * sh[3];

		if (deg > 1)
		{
			float xx = x * x, yy = y * y, zz = z * z;
			float xy = x * y, yz = y * z, xz = x * z;
			result = result +
				SH_C2[0] * xy * sh[4] +
				SH_C2[1] * yz * sh[5] +
				SH_C2[2] * (2.0f * zz - xx - yy) * sh[6] +
				SH_C2[3] * xz * sh[7] +
				SH_C2[4] * (xx - yy) * sh[8];

			if (deg > 2)
			{
				result = result +
					SH_C3[0] * y * (3.0f * xx - yy) * sh[9] +
					SH_C3[1] * xy * z * sh[10] +
					SH_C3[2] * y * (4.0f * zz - xx - yy) * sh[11] +
					SH_C3[3] * z * (2.0f * zz - 3.0f * xx - 3.0f * yy) * sh[12] +
					SH_C3[4] * x * (4.0f * zz - xx - yy) * sh[13] +
					SH_C3[5] * z * (xx - yy) * sh[14] +
					SH_C3[6] * x * (xx - 3.0f * yy) * sh[15];
			}
		}
	}
	result += 0.5f;

	// RGB colors are clamped to positive values. If values are
	// clamped, we need to keep track of this for the backward pass.
	clamped[3 * idx + 0] = (result.x < 0);
	clamped[3 * idx + 1] = (result.y < 0);
	clamped[3 * idx + 2] = (result.z < 0);
    colors[idx] = glm::max(result, 0.0f);
}

__global__ void ComputeColorFromSHBackwardCUDAKernel(
	const int P, const int deg, const int max_coeffs, 
	const glm::vec3* dirs, 
	const glm::vec3* shs, 
	const bool* visibility_filter,
	const bool* clamped, 
	const glm::vec3* dL_dcolors, 
	glm::vec3* dL_ddirs, 
	glm::vec3* dL_dshs)
{
	auto idx = cg::this_grid().thread_rank();
	if (idx >= P || !visibility_filter[idx])
		return;
	// Compute intermediate values, as it is done during forward
	glm::vec3 dir = dirs[idx];

	const glm::vec3* sh = shs + idx * max_coeffs;

	// Use PyTorch rule for clamping: if clamping was applied,
	// gradient becomes 0.
	glm::vec3 dL_dcolor = dL_dcolors[idx];
	dL_dcolor.x *= clamped[3 * idx + 0] ? 0 : 1;
	dL_dcolor.y *= clamped[3 * idx + 1] ? 0 : 1;
	dL_dcolor.z *= clamped[3 * idx + 2] ? 0 : 1;

	glm::vec3 dRGBdx(0, 0, 0);
	glm::vec3 dRGBdy(0, 0, 0);
	glm::vec3 dRGBdz(0, 0, 0);
	float x = dir.x;
	float y = dir.y;
	float z = dir.z;

	// Target location for this Gaussian to write SH gradients to
	glm::vec3* dL_dsh = dL_dshs + idx * max_coeffs;

	// No tricks here, just high school-level calculus.
	float dRGBdsh0 = SH_C0;
	dL_dsh[0] = dRGBdsh0 * dL_dcolor;
	if (deg > 0)
	{
		float dRGBdsh1 = -SH_C1 * y;
		float dRGBdsh2 = SH_C1 * z;
		float dRGBdsh3 = -SH_C1 * x;
		dL_dsh[1] = dRGBdsh1 * dL_dcolor;
		dL_dsh[2] = dRGBdsh2 * dL_dcolor;
		dL_dsh[3] = dRGBdsh3 * dL_dcolor;

		dRGBdx = -SH_C1 * sh[3];
		dRGBdy = -SH_C1 * sh[1];
		dRGBdz = SH_C1 * sh[2];

		if (deg > 1)
		{
			float xx = x * x, yy = y * y, zz = z * z;
			float xy = x * y, yz = y * z, xz = x * z;

			float dRGBdsh4 = SH_C2[0] * xy;
			float dRGBdsh5 = SH_C2[1] * yz;
			float dRGBdsh6 = SH_C2[2] * (2.f * zz - xx - yy);
			float dRGBdsh7 = SH_C2[3] * xz;
			float dRGBdsh8 = SH_C2[4] * (xx - yy);
			dL_dsh[4] = dRGBdsh4 * dL_dcolor;
			dL_dsh[5] = dRGBdsh5 * dL_dcolor;
			dL_dsh[6] = dRGBdsh6 * dL_dcolor;
			dL_dsh[7] = dRGBdsh7 * dL_dcolor;
			dL_dsh[8] = dRGBdsh8 * dL_dcolor;

			dRGBdx += SH_C2[0] * y * sh[4] + SH_C2[2] * 2.f * -x * sh[6] + SH_C2[3] * z * sh[7] + SH_C2[4] * 2.f * x * sh[8];
			dRGBdy += SH_C2[0] * x * sh[4] + SH_C2[1] * z * sh[5] + SH_C2[2] * 2.f * -y * sh[6] + SH_C2[4] * 2.f * -y * sh[8];
			dRGBdz += SH_C2[1] * y * sh[5] + SH_C2[2] * 2.f * 2.f * z * sh[6] + SH_C2[3] * x * sh[7];

			if (deg > 2)
			{
				float dRGBdsh9 = SH_C3[0] * y * (3.f * xx - yy);
				float dRGBdsh10 = SH_C3[1] * xy * z;
				float dRGBdsh11 = SH_C3[2] * y * (4.f * zz - xx - yy);
				float dRGBdsh12 = SH_C3[3] * z * (2.f * zz - 3.f * xx - 3.f * yy);
				float dRGBdsh13 = SH_C3[4] * x * (4.f * zz - xx - yy);
				float dRGBdsh14 = SH_C3[5] * z * (xx - yy);
				float dRGBdsh15 = SH_C3[6] * x * (xx - 3.f * yy);
				dL_dsh[9] = dRGBdsh9 * dL_dcolor;
				dL_dsh[10] = dRGBdsh10 * dL_dcolor;
				dL_dsh[11] = dRGBdsh11 * dL_dcolor;
				dL_dsh[12] = dRGBdsh12 * dL_dcolor;
				dL_dsh[13] = dRGBdsh13 * dL_dcolor;
				dL_dsh[14] = dRGBdsh14 * dL_dcolor;
				dL_dsh[15] = dRGBdsh15 * dL_dcolor;

				dRGBdx += (
					SH_C3[0] * sh[9] * 3.f * 2.f * xy +
					SH_C3[1] * sh[10] * yz +
					SH_C3[2] * sh[11] * -2.f * xy +
					SH_C3[3] * sh[12] * -3.f * 2.f * xz +
					SH_C3[4] * sh[13] * (-3.f * xx + 4.f * zz - yy) +
					SH_C3[5] * sh[14] * 2.f * xz +
					SH_C3[6] * sh[15] * 3.f * (xx - yy));

				dRGBdy += (
					SH_C3[0] * sh[9] * 3.f * (xx - yy) +
					SH_C3[1] * sh[10] * xz +
					SH_C3[2] * sh[11] * (-3.f * yy + 4.f * zz - xx) +
					SH_C3[3] * sh[12] * -3.f * 2.f * yz +
					SH_C3[4] * sh[13] * -2.f * xy +
					SH_C3[5] * sh[14] * -2.f * yz +
					SH_C3[6] * sh[15] * -3.f * 2.f * xy);

				dRGBdz += (
					SH_C3[1] * sh[10] * xy +
					SH_C3[2] * sh[11] * 4.f * 2.f * yz +
					SH_C3[3] * sh[12] * 3.f * (2.f * zz - xx - yy) +
					SH_C3[4] * sh[13] * 4.f * 2.f * xz +
					SH_C3[5] * sh[14] * (xx - yy));
			}
		}
	}

	glm::vec3 dL_ddir(glm::dot(dRGBdx, dL_dcolor), glm::dot(dRGBdy, dL_dcolor), glm::dot(dRGBdz, dL_dcolor));
	dL_ddirs[idx] = dL_ddir;
}

void ComputeColorFromSHForwardCUDA(
    const int P, const int deg, const int max_coeffs,
    const float* dirs,
    const float* shs,
    const bool* visibility_filter,
    float* colors,
    bool* clamped)
{
	ComputeColorFromSHForwardCUDAKernel <<<(P + 255) / 256, 256 >>> (
        P, deg, max_coeffs, 
        (const glm::vec3*)dirs, 
        (const glm::vec3*)shs, 
		visibility_filter,
        (glm::vec3*)colors,
        clamped
    );
}

void ComputeColorFromSHBackwardCUDA(
    const int P, const int deg, const int max_coeffs,
    const float* dirs,
    const float* shs,
    const bool* visibility_filter,
    const bool* clamped,
	const float* dL_dcolors,
	float* dL_ddirs,
	float* dL_dshs
)
{
	ComputeColorFromSHBackwardCUDAKernel <<<(P + 255) / 256, 256 >>> (
        P, deg, max_coeffs, 
        (const glm::vec3*)dirs, 
        (const glm::vec3*)shs, 
		visibility_filter,
        clamped,
        (glm::vec3*)dL_dcolors,
		(glm::vec3*)dL_ddirs,
		(glm::vec3*)dL_dshs
    );
}
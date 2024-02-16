/**
 * @file compute_cov3d_kernel.cu
 * @brief CUDA kernel to compute 3D covariance matrices. 
 */

#include <utils.h>
#include <glm/glm.hpp>
#include <cooperative_groups.h>
#include <cooperative_groups/reduce.h>
#include <torch/torch.h>

namespace cg = cooperative_groups;



/**
 * @brief Helper function: transform a scaling vector to matrix
 * 
 * @param[in] scale     Scaling vector
 * @return Scaling Matrix 
 */
__device__ inline glm::mat3 scale_vector_to_matrix(const glm::vec3 scale)
{
    glm::mat3 S = glm::mat3(1.0f);
    
    S[0][0] = scale.x;
    S[1][1] = scale.y;
    S[2][2] = scale.z;

    return S;
}

/**
 * @brief Helper function: transform a unit quaternion to rotmatrix
 * 
 * @param[in] uquat    Unit quaternion
 * @return Rotation matrix
 */
__device__ inline glm::mat3 unit_quaternion_to_rotmatrix(const glm::vec4 uquat)
{
    float r = uquat.x;
    float x = uquat.y;
    float y = uquat.z;
    float z = uquat.w;

    return glm::mat3(
        1.f - 2.f * (y * y + z * z), 
        2.f * (x * y - r * z), 
        2.f * (x * z + r * y),
        2.f * (x * y + r * z), 
        1.f - 2.f * (x * x + z * z), 
        2.f * (y * z - r * x),
        2.f * (x * z - r * y), 
        2.f * (y * z + r * x), 
        1.f - 2.f * (x * x + y * y)
    );
}


/**
 * @brief Forward process on the device: converting the scaling and rotation 
 *        of a 3D Gaussian into a covariance matrix.
 * 
 * @param[in] scale    Scaling vector
 * @param[in] quat     Unit quaternion
 * @param[out] cov3D   Covariance vector, the upper right part of the covariance matrix
 */
__device__ void compute_cov3d_forward(
    const glm::vec3 scale, 
    const glm::vec4 quat, 
    float* cov3D)
{
	glm::mat3 S = scale_vector_to_matrix(scale);
	glm::mat3 R = unit_quaternion_to_rotmatrix(quat);

    // Note: Colume Major, and right multiply.
	glm::mat3 M = S * R;
    glm::mat3 Sigma = glm::transpose(M) * M;

    cov3D[0] = Sigma[0][0]; cov3D[1] = Sigma[0][1]; 
    cov3D[2] = Sigma[0][2]; cov3D[3] = Sigma[1][1]; 
    cov3D[4] = Sigma[1][2]; cov3D[5] = Sigma[2][2];
}

/**
 * @brief Backward process on the device: converting the scaling and rotation 
 *        of a 3D Gaussian into a covariance matrix.
 * 
 * @param[in] scale       Scaling vector
 * @param[in] quat        Unit quaternion
 * @param[in] dL_dcov3D   loss gradient w.r.t. covariance vector
 * @param[out] dL_dscale  loss gradient w.r.t. scale vector
 * @param[out] dL_dquat   loss gradient w.r.t. unit quaternion
 */
__device__ void compute_cov3_backward(
    const glm::vec3 scale, 
    const glm::vec4 quat, 
    const float* dL_dcov3D, 
    glm::vec3& dL_dscale, 
    glm::vec4& dL_dquat)
{
    glm::mat3 S = scale_vector_to_matrix(scale);
    glm::mat3 R = unit_quaternion_to_rotmatrix(quat);
    glm::mat3 M = S * R;

    // Convert covariance loss gradients from vector to matrix
    glm::mat3 dL_dSigma = glm::mat3(
        dL_dcov3D[0], 0.5f * dL_dcov3D[1], 0.5f * dL_dcov3D[2],
        0.5f * dL_dcov3D[1], dL_dcov3D[3], 0.5f * dL_dcov3D[4],
        0.5f * dL_dcov3D[2], 0.5f * dL_dcov3D[4], dL_dcov3D[5]
    );

    // Loss gradient w.r.t. matrix M
    // dSigma_dM = 2 * M
    glm::mat3 dL_dM = 2.0f * M * dL_dSigma;

    // Loss gradient w.r.t. scale
    glm::mat3 Rt = glm::transpose(R);
    glm::mat3 dL_dMt = glm::transpose(dL_dM);

    dL_dscale.x = glm::dot(Rt[0], dL_dMt[0]);
    dL_dscale.y = glm::dot(Rt[1], dL_dMt[1]);
    dL_dscale.z = glm::dot(Rt[2], dL_dMt[2]);

    dL_dMt[0] *= scale.x;
    dL_dMt[1] *= scale.y;
    dL_dMt[2] *= scale.z;

    // Loss gradients w.r.t. unit quaternion
    float r = quat.x;
    float x = quat.y;
    float y = quat.z;
    float z = quat.w;

    dL_dquat.x = 2 * z * (dL_dMt[0][1] - dL_dMt[1][0]) +
              2 * y * (dL_dMt[2][0] - dL_dMt[0][2]) +
              2 * x * (dL_dMt[1][2] - dL_dMt[2][1]);
    dL_dquat.y = 2 * y * (dL_dMt[1][0] + dL_dMt[0][1]) +
              2 * z * (dL_dMt[2][0] + dL_dMt[0][2]) +
              2 * r * (dL_dMt[1][2] - dL_dMt[2][1]) -
              4 * x * (dL_dMt[2][2] + dL_dMt[1][1]);
    dL_dquat.z = 2 * x * (dL_dMt[1][0] + dL_dMt[0][1]) +
              2 * r * (dL_dMt[2][0] - dL_dMt[0][2]) +
              2 * z * (dL_dMt[1][2] + dL_dMt[2][1]) -
              4 * y * (dL_dMt[2][2] + dL_dMt[0][0]);
    dL_dquat.w = 2 * r * (dL_dMt[0][1] - dL_dMt[1][0]) +
              2 * x * (dL_dMt[2][0] + dL_dMt[0][2]) +
              2 * y * (dL_dMt[1][2] + dL_dMt[2][1]) -
              4 * z * (dL_dMt[1][1] + dL_dMt[0][0]);
}

/**
 * @brief CUDA kernel for computing 3D covariance matrices in a forward pass. 
 * 
 * @param[in] P                   Number of points to process.
 * @param[in] scales              Array of 3D scales for each point.
 * @param[in] uquats              Array of 3D rotations (unit quaternions) for each point.
 * @param[in] visible   Array indicating the visibility status of each point.
 * @param[out] cov3Ds             Output array for storing the computed 3D covariance vectors. 
 */
__global__ void computeCov3DForwardCUDAKernel(
    const int P,
    const glm::vec3* scales,
    const glm::vec4* uquats,
    const bool* visible,
    float* cov3Ds)
{
    auto idx = cg::this_grid().thread_rank();
    if (idx >= P || !visible[idx])
        return;

    compute_cov3d_forward(
        scales[idx], 
        uquats[idx], 
        cov3Ds + 6 * idx
    );
}

/**
 * @brief CUDA kernel for computing gradients in a backward pass of 3D covariance computation.
 *
 * @param[in] P                    Number of points to process.
 * @param[in] scales               Array of 3D scales for each point.
 * @param[in] uquats               Array of 3D rotations (unit quaternions) for each point.
 * @param[in] visible    Array indicating the visibility status of each point.
 * @param[in] dL_dcov3Ds           Gradients of the loss with respect to the 3D covariance matrices.
 * @param[out] dL_dscales          Output array for storing the gradients of the loss with respect to scales.
 * @param[out] dL_duquats          Output array for storing the gradients of the loss with respect to unit quaternions.
 */
__global__ void computeCov3DBackwardCUDAKernel(
    const int P,
    const glm::vec3* scales,
    const glm::vec4* uquats,
    const bool* visible,
    const float* dL_dcov3Ds,
    glm::vec3* dL_dscales,
    glm::vec4* dL_duquats)
{
    auto idx = cg::this_grid().thread_rank();
    if (idx >= P || !visible[idx])
        return;

    compute_cov3_backward(
        scales[idx], 
        uquats[idx], 
        dL_dcov3Ds + 6 * idx, 
        dL_dscales[idx], 
        dL_duquats[idx]
    );
}


torch::Tensor
computeCov3DForward(
  const torch::Tensor& scales,
  const torch::Tensor& uquats,
  const torch::Tensor& visible
){

    CHECK_INPUT(scales);
    CHECK_INPUT(uquats);
    CHECK_INPUT(visible);

    const int P = scales.size(0);
    auto float_opts = scales.options().dtype(torch::kFloat32);
    torch::Tensor cov3Ds = torch::zeros({P, 6}, float_opts);
    if(P != 0)
    {
        computeCov3DForwardCUDAKernel <<<(P + 255) / 256, 256 >>> (
            P, 
            (glm::vec3*)scales.contiguous().data_ptr<float>(), 
            (glm::vec4*)uquats.contiguous().data_ptr<float>(), 
            visible.contiguous().data_ptr<bool>(),
            cov3Ds.data_ptr<float>()
        );
    }

    return cov3Ds;
}



std::tuple<torch::Tensor, torch::Tensor>
computeCov3DBackward(
    const torch::Tensor& scales,
	const torch::Tensor& uquats,
	const torch::Tensor& visible,
	const torch::Tensor& dL_dcov3Ds
){

    CHECK_INPUT(scales);
    CHECK_INPUT(uquats);
    CHECK_INPUT(visible);
    CHECK_INPUT(dL_dcov3Ds);

    const int P = scales.size(0);
    auto float_opts = scales.options().dtype(torch::kFloat32);
    torch::Tensor dL_dscales = torch::zeros({P, 3}, float_opts);
    torch::Tensor dL_duquats = torch::zeros({P, 4}, float_opts);
    
    if(P != 0)
    {
        computeCov3DBackwardCUDAKernel <<<(P + 255) / 256, 256 >>> (
            P, 
            (glm::vec3*)scales.contiguous().data_ptr<float>(), 
            (glm::vec4*)uquats.contiguous().data_ptr<float>(), 
            visible.contiguous().data_ptr<bool>(),
            dL_dcov3Ds.contiguous().data_ptr<float>(), 
            (glm::vec3*)dL_dscales.data_ptr<float>(), 
            (glm::vec4*)dL_duquats.data_ptr<float>()
        );
    }

    return std::make_tuple(dL_dscales, dL_duquats);
}

#include <project_point.h>
#include <compute_cov3d.h>
#include <ewa_project.h>
#include <sort_gaussian.h>
#include <compute_sh.h>


PYBIND11_MODULE(TORCH_EXTENSION_NAME, m) {
    m.def("project_point_forward", &projectPointsForward);
    m.def("project_point_backward", &projectPointsBackward);
    m.def("compute_cov3d_forward", &computeCov3DForward);
    m.def("compute_cov3d_backward", &computeCov3DBackward);
    m.def("ewa_project_forward", &EWAProjectForward);
    m.def("ewa_project_backward", &EWAProjectBackward);
    m.def("compute_gaussian_key", &computeGaussianKey);
    m.def("compute_tile_gaussian_range", &computeTileGaussianRange);
    m.def("compute_sh_forward", &computeSHForward);
    m.def("compute_sh_backward", &computeSHBackward);
}


import os
import torch
import torch.nn as nn
import math
import numpy as np
from tqdm import tqdm
import dptr.gs as gs
import matplotlib.pyplot as plt
from PIL import Image

class SimpleGaussian:
    def __init__(self, num_points=100000):
        
        N = int(num_points)
        self._attributes = {
            "xyz":      torch.rand((N, 3), dtype=torch.float32).cuda() * 2 - 1,
            "scale":    torch.rand((N, 3), dtype=torch.float32).cuda(),
            "rotate":   torch.rand((N, 4), dtype=torch.float32).cuda(),
            "opacity":  torch.rand((N, 1), dtype=torch.float32).cuda(),
            "rgb":      torch.rand((N, 3), dtype=torch.float32).cuda()
        }
        
        self._activations = {
            "scale": torch.exp,
            "rotate": torch.nn.functional.normalize,
            "opacity": torch.sigmoid,
            "rgb": torch.sigmoid
        }
        
        for attribute_name in self._attributes.keys():
            self._attributes[attribute_name] = nn.Parameter(self._attributes[attribute_name]).requires_grad_(True)
        
        self.optimizer = torch.optim.Adam(list(self._attributes.values()), lr=0.01)
        
    def step(self):
        self.optimizer.step()
        self.optimizer.zero_grad()
    
    def get_attribute(self, name):
        try:
            if name in self._activations.keys() and self._activations[name] is not None:
                return self._activations[name](self._attributes[name])
            else:
                return self._attributes[name]
        except:
            raise ValueError(f"Attribute or activation for {name} is not VALID!")


if __name__ == "__main__":
    # seed = 123
    # torch.manual_seed(seed)
    
    bg = 0
    image_file = "./media/DPTR.png"
    img = np.array(Image.open(image_file))
    img = img.astype(np.float32) / 255.0
    gt = torch.from_numpy(img).cuda().permute(2, 0, 1)
    
    C, H, W = gt.shape 
    
    bg = 0
    fov_x = math.pi / 2.0
    fx = 0.5 * float(W) / math.tan(0.5 * fov_x)
    camparam = torch.Tensor([fx, fx, float(W) / 2, float(H) / 2]).cuda().float()
    viewmat = torch.Tensor([[1.0, 0.0, 0.0, 0.0],
                            [0.0, 1.0, 0.0, 0.0],
                            [0.0, 0.0, 1.0, 0.0],
                            [0.0, 0.0, 8.0, 1.0]]).cuda().float()
    projmat = viewmat.clone()
    
    gaussians = SimpleGaussian(num_points=100000)
    
    max_iter = 7000
    frames = []
    progress_bar = tqdm(range(1, max_iter), desc="Training")
    l1_loss = nn.L1Loss()
    
    for iteration in range(0, max_iter):
        # project points
        (
            uv,
            depth 
        ) = gs.project_point(
            gaussians.get_attribute("xyz"), 
            viewmat, 
            projmat,
            camparam,
            W, H)
        
        visibility_status = depth != 0
        
        # compute cov3d
        cov3d = gs.compute_cov3d(
            gaussians.get_attribute("scale"), 
            gaussians.get_attribute("rotate"), 
            visibility_status)
        
        # ewa project
        (
            conic, 
            radius, 
            tiles
        ) = gs.ewa_project(
            gaussians.get_attribute("xyz"),
            cov3d, 
            viewmat,
            camparam,
            uv,
            W, H,
            visibility_status
        )
        
        # sort
        (
            idx_sorted, 
            tile_bins
        ) = gs.sort_gaussian(
            uv, 
            depth, 
            W, H, 
            radius, 
            tiles
        )
        
        # alpha blending
        render_feature = gs.alpha_blending(
            uv, 
            conic, 
            gaussians.get_attribute("opacity"), 
            gaussians.get_attribute("rgb"), 
            idx_sorted, 
            tile_bins, 
            bg, 
            W, 
            H
        )
        
        loss = l1_loss(render_feature, gt)
        loss.backward()
        
        gaussians.step()
        
        valid_num = torch.sum(visibility_status.float())
        progress_bar.set_postfix({"Loss": f"{loss:.{7}f}", "valid_num": f"{valid_num}"})
        progress_bar.update(1)
        
        if iteration % 100 == 0:
            show_data = render_feature.detach().permute(1, 2, 0)
            show_data = torch.clamp(show_data, 0.0, 1.0)
            frames.append((show_data.cpu().numpy() * 255).astype(np.uint8))
    
    progress_bar.close()
    
    # save them as a gif with PIL
    frames = [Image.fromarray(frame) for frame in frames]
    out_dir = "media"
    os.makedirs(out_dir, exist_ok=True)
    frames[0].save(
        f"{out_dir}/tutorial.gif",
        save_all=True,
        append_images=frames[1:],
        optimize=False,
        duration=5,
        loop=0,
    )
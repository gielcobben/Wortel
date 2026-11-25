// The photo a stage stands on, as the custom properties site.css reads
// (.stage::before): which of the four, which part of it, and how far in.
//   at    a background-position, in percentages: '0% 12%'
//   zoom  1 is the photo filling the stage. 2 is twice as wide as the stage,
//         for a closer crop. Whatever the number, the photo never comes out
//         smaller than the stage: on a phone, where a stage is taller than it
//         is wide, a width alone left a bare band under the picture.
export const photo = (name = 'lake', at = '50% 62%', zoom = 1) =>
  `--photo:url(/img/${name}.jpg);--photo-s:url(/img/${name}-1600.webp);--at:${at};--ax:${parseFloat(at) / 100};--zoom:${zoom}`;

import argparse

from cloudvolume.lib import Bbox, Vec
from taskqueue import TaskQueue

import synaptor.cloud.kube.parser as parser
import synaptor.cloud.kube.task_creation as tc


def main(configfilename):

    config = parser.parse(configfilename)

    startcoord = Vec(*config["startcoord"])
    volshape = Vec(*config["vol_shape"])

    bounds = Bbox(startcoord, startcoord + volshape)

    iterator = tc.create_connected_component_tasks(
                   config["descriptor"], config["temp_output"],
                   storagestr=config["storagestrs"][0],
                   storagedir=config["storagestrs"][1],
                   cc_thresh=config["ccthresh"], sz_thresh=config["szthresh"],
                   bounds=bounds, shape=config["chunk_shape"],
                   mip=config["voxelres"], hashmax=config["num_merge_tasks"])

    tq = TaskQueue(config["queueurl"])
    tq.insert_all(iterator)


if __name__ == "__main__":

    argparser = argparse.ArgumentParser()

    argparser.add_argument("configfilename")

    args = argparser.parse_args()

    main(args.configfilename)
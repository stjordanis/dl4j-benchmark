FROM dl4j-benchmark-base:1.0.0 as builder

# add actual run params here
CMD ["/usr/bin/java", "-Xmx512M", "-Dorg.bytedeco.javacpp.maxbytes=512M", "-Dorg.bytedeco.javacpp.maxphysicalbytes=1G", "-cp", "/app/memory-testing/target/memory-testing-2.0-SNAPSHOT-bin.jar", "ai.skymind.PWTestRun", "--dataClass", "ai.skymind.pipeline.ImgRRPipeline", "--modelClass", "ai.skymind.models.dl4j.CNN2DModelMLN"]
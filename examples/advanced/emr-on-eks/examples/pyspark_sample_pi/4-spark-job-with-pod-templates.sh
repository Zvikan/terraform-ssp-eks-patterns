#!/bin/bash
#  You can use pod template files to define the driver or executor pod’s configurations that Spark configurations do not support.
# see Pod Template (https://spark.apache.org/docs/3.0.0-preview/running-on-kubernetes.html#pod-template).

# INPUT VARIABLES 
EMR_ON_EKS_ROLE_ID="aws001-preprod-test-emr-eks-data-team-a"       # Replace EMR IAM role with your ID
EKS_CLUSTER_ID='aws001-preprod-test-eks'                           # Replace cluster id with your id
EMR_ON_EKS_NAMESPACE='emr-data-team-a'                             # Replace namespace with your namespace
JOB_NAME='taxidata'                                   

S3_BUCKET='s3://<enter-pre-created-bucket-name>'                   # Create your own s3 bucket and replace this value
CW_LOG_GROUP="/emr-on-eks-logs/${EKS_CLUSTER_ID}/${EMR_ON_EKS_NAMESPACE}" # Create CW Log group if not exist
SPARK_JOB_S3_PATH="${S3_BUCKET}/${EKS_CLUSTER_ID}/${EMR_ON_EKS_NAMESPACE}/${JOB_NAME}"

# Step1: COPY POD TEMPLATES TO S3 Bucket
aws s3 sync ./pyspark/ "${SPARK_JOB_S3_PATH}/"

# FIND ROLE ARN and EMR VIRTUAL CLUSTER ID 
EMR_ROLE_ARN=$(aws iam get-role --role-name $EMR_ON_EKS_ROLE_ID --query Role.Arn --output text)
VIRTUAL_CLUSTER_ID=$(aws emr-containers list-virtual-clusters --query "virtualClusters[?name=='${EKS_CLUSTER_ID}' && state=='RUNNING'].id" --output text)

# Execute Spark job
if [[ $VIRTUAL_CLUSTER_ID != "" ]]; then
  echo "Found Cluster $EKS_CLUSTER_ID; Executing the Spark job now..."
  aws emr-containers start-job-run \
    --virtual-cluster-id $VIRTUAL_CLUSTER_ID \
    --name $JOB_NAME \
    --execution-role-arn $EMR_ROLE_ARN \
    --release-label emr-6.3.0-latest \
    --job-driver '{
      "sparkSubmitJobDriver": {
        "entryPoint": "'"$SPARK_JOB_S3_PATH"'/scripts/spark-taxi-trip-data.py",
        "entryPointArguments": ["'"$SPARK_JOB_S3_PATH"'/input/taxi-trip-data/",
          "'"$SPARK_JOB_S3_PATH"'/ouput/taxi-trip-data/", "taxitripdata"
        ],
        "sparkSubmitParameters": "--conf spark.executor.instances=2 --conf spark.executor.memory=2G --conf spark.executor.cores=2 --conf spark.driver.cores=1"
      }
   }' \
    --configuration-overrides '{
      "applicationConfiguration": [
          {
            "classification": "spark-defaults", 
            "properties": {
              "spark.hadoop.hive.metastore.client.factory.class":"com.amazonaws.glue.catalog.metastore.AWSGlueDataCatalogHiveClientFactory",
              "spark.driver.memory":"2G",
              "spark.kubernetes.driver.podTemplateFile":"'"$SPARK_JOB_S3_PATH"'/scripts/spark-driver-pod-template.yaml",
              "spark.kubernetes.executor.podTemplateFile":"'"$SPARK_JOB_S3_PATH"'/scripts/spark-executor-pod-template.yaml",
              "spark.kubernetes.executor.podNamePrefix":"taxidata"
            }
          }
        ], 
      "monitoringConfiguration": {
        "persistentAppUI":"ENABLED",
        "cloudWatchMonitoringConfiguration": {
          "logGroupName":"'"$CW_LOG_GROUP"'",
          "logStreamNamePrefix":"'"$JOB_NAME"'"
        },
        "s3MonitoringConfiguration": {
          "logUri":"'"$SPARK_JOB_S3_PATH"'/logs/"
        }
      }
    }'
else
  echo "Cluster is not in running state $EKS_CLUSTER_ID"
fi


aws cloudformation create-stack --stack-name rds-example --template-body file://rds-example.yml --parameters file://rds-params.json --region=us-east-1

aws cloudformation update-stack --stack-name rds-example --template-body file://rds-example.yml --parameters file://rds-params.json --region=us-east-1

aws cloudformation create-stack --stack-name s3-example --template-body file://s3.yml --region=us-east-1

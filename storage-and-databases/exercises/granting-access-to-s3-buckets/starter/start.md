aws cloudformation create-stack --stack-name s3exercise --template-body file://starter.yml --region=us-east-1

aws cloudformation update-stack --stack-name s3exercise --template-body file://starter.yml --region=us-east-1

aws cloudformation update-stack --stack-name s3-exercise --template-body file://starter.yml --region us-east-1 --capabilities CAPABILITY_NAMED_IAM

aws cloudformation validate-template --template-body file://starter.yml

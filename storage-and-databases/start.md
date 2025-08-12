aws cloudformation create-stack --stack-name rds-example --template-body file://rds-example.yml --parameters file://rds-params.json --region=us-east-1

aws cloudformation update-stack --stack-name rds-example --template-body file://rds-example.yml --parameters file://rds-params.json --region=us-east-1

aws cloudformation create-stack --stack-name s3-example --template-body file://s3.yml --region=us-east-1

aws cloudformation create-stack --stack-name cd12352-lesson-changesets --template-body file://vpc.yml --region us-east-1

aws cloudformation create-change-set --stack-name cd12352-lesson-changesets --template-body file://vpc-tagged.yml --change-set-name tagging-resources --region us-east-1

aws cloudformation describe-change-set --stack-name cd12352-lesson-changesets --change-set-name tagging-resources --region us-east-1

aws cloudformation execute-change-set --stack-name cd12352-lesson-changesets --change-set-name tagging-resources --region us-east-1

aws cloudformation deploy --stack-name cd12352-lesson-changesets --template-file vpc-tagged.yml --no-execute-changeset --region us-east-1

aws cloudformation delete-change-set --stack-name cd12352-lesson-changesets --change-set-name awscli-cloudformation-package-deploy-1755016744 --region us-east-1


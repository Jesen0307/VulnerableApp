pipeline {
    agent any

    environment {
        REPORTS_DIR = 'security-reports'
        SONAR_HOST_URL = 'http://sonarqube:9000'
        PATH = "/opt/sonar-scanner/bin:${env.PATH}"
        SONAR_TOKEN = credentials('sonar-token')
        SONAR_PROJECT_KEY = 'VulnerableApp'

        // --- DefectDojo (POC: hardcoded, replace with Jenkins credentials later) ---
        DD_URL = 'http://defectdojo-nginx:8080'
        DD_API_KEY = credentials('DEFECTDOJO_API_KEY')
        DD_ENGAGEMENT_NAME = 'POC'
    }

    stages {
        stage('Install Dependencies') {
            steps {
                sh '''
                    sudo apt-get update
                    sudo apt-get install -y python3 python3-pip python3-venv curl unzip docker.io default-jdk

                    if [ ! -d "/usr/lib/jvm/java-17-temurin" ]; then
                        sudo mkdir -p /usr/lib/jvm/java-17-temurin
                        curl -sL "https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse" | sudo tar -xz -C /usr/lib/jvm/java-17-temurin --strip-components=1
                    fi

                    SONAR_SCANNER_VERSION=8.1.0.6389
                    if [ ! -x /opt/sonar-scanner/bin/sonar-scanner ]; then
                        sudo mkdir -p /opt/sonar-scanner
                        curl -fsSL "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}-linux-x64.zip" -o /tmp/sonar-scanner.zip
                        sudo unzip -q /tmp/sonar-scanner.zip -d /tmp/sonar-scanner-install
                        sudo cp -r /tmp/sonar-scanner-install/sonar-scanner-*/. /opt/sonar-scanner/
                        sudo chmod -R +x /opt/sonar-scanner/bin /opt/sonar-scanner/jre/bin
                        rm -rf /tmp/sonar-scanner.zip /tmp/sonar-scanner-install
                    fi

                    # Install OpenCode CLI (required by the aiAgent step)
                    if ! command -v opencode >/dev/null 2>&1; then
                        sudo apt-get install -y nodejs npm
                        sudo npm install -g opencode-ai
                    fi
                    opencode --version
                '''
            }
        }

        stage('Build (Compile Java)') {
            steps {
                sh 'chmod +x gradlew'
                sh './gradlew classes printRuntimeClasspath --no-daemon'
            }
        }

        stage('SAST (SonarQube)') {
            steps {
                sh 'mkdir -p $REPORTS_DIR'
                sh 'chmod +x scripts/sonarqube-scan.sh'
                sh './scripts/sonarqube-scan.sh . $SONAR_PROJECT_KEY $SONAR_HOST_URL $SONAR_TOKEN $REPORTS_DIR'
            }
        }
    }

    post {
        always {
            echo 'Pipeline execution completed. Running AI review...'

            aiAgent agent: openCode(),
                    apiCredentialsId: 'OpenCode',
                    approvalTimeoutSeconds: 1,
                    failOnAgentError: false,
                    model: 'opencode/deepseek-v4.1-flash-free',
                    prompt: """Review this project and summarize it. Use the findings in ${env.REPORTS_DIR}/sonar_raw.json as context.
Save your final review to the file ${env.REPORTS_DIR}/Agentreview.json.
The file must contain only valid JSON (no markdown, no code fences) with these keys:
"summary" (string), "key_risks" (array of strings), "recommendations" (array of strings).""",
                    yoloMode: true


            archiveArtifacts artifacts: "${env.REPORTS_DIR}/sonar_raw.json, ${env.REPORTS_DIR}/Agentreview.json", allowEmptyArchive: true

            script {
                env.DD_ENGAGEMENT_ID = sh(returnStdout: true, script: '''
                    curl -sS -H "Authorization: Token $DD_API_KEY" \
                      "$DD_URL/api/v2/engagements/?name=$DD_ENGAGEMENT_NAME" \
                      | python3 -c "import sys,json; r=json.load(sys.stdin).get('results',[]); print(r[0]['id'] if r else '')"
                ''').trim()
                echo "DefectDojo engagement '${env.DD_ENGAGEMENT_NAME}' resolved to ID '${env.DD_ENGAGEMENT_ID}'"
            }

            sh '''
                for f in sonar_raw.json Agentreview.json; do
                  if [ -f "$REPORTS_DIR/$f" ]; then
                    echo "Uploading $f to DefectDojo engagement $DD_ENGAGEMENT_ID"
                    curl -sS --fail -X POST "$DD_URL/api/v2/engagements/$DD_ENGAGEMENT_ID/files/" \
                      -H "Authorization: Token $DD_API_KEY" \
                      -F "title=$f - build $BUILD_NUMBER" \
                      -F "file=@$REPORTS_DIR/$f" || echo "WARNING: upload of $f failed"
                  else
                    echo "WARNING: $REPORTS_DIR/$f not found, skipping upload"
                  fi
                done
            '''

            sh '''
                if [ -f "$REPORTS_DIR/sonar_raw.json" ]; then
                  curl -sS --fail -X POST "$DD_URL/api/v2/import-scan/" \
                    -H "Authorization: Token $DD_API_KEY" \
                    -F "scan_type=SonarQube Scan" \
                    -F "engagement=$DD_ENGAGEMENT_ID" \
                    -F "test_title=SonarQube - build $BUILD_NUMBER" \
                    -F "active=true" \
                    -F "verified=false" \
                    -F "file=@$REPORTS_DIR/sonar_raw.json" || echo "WARNING: findings import failed"
                else
                  echo "WARNING: sonar_raw.json not found, skipping findings import"
                fi
            '''
        }
    }
}
